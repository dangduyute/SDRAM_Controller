# SDRAM Controller – RTL & Testbench Verification

This repository contains a **Verilog-based SDRAM controller**, a **behavioral SDRAM model**, and a **self-checking testbench**.  

---

## 1. RTL Design (`sdram_ctrl.v`)

### 1.1 Overview

The RTL implements a **single-data-rate SDRAM controller** with a **16-bit data bus**

The design focuses on:
- Correct SDRAM **initialization sequence**
- **Single-beat READ/WRITE** transactions
- **Auto-precharge** support
- **CAS latency (CL) awareness**
- Clean **host/controller handshake**
- Cycle-accurate timing for simulation and learning purposes

All critical SDRAM timing parameters are configurable through Verilog parameters, making the controller easy to adapt for different SDRAM devices or simulation requirements.

---

## 1.2 Interfaces

This section describes all external interfaces of the SDRAM controller, including
signal directions, functional roles, and handshake behavior.


#### A) Host Command Interface

The host interface provides a **simple request–response protocol** between a host
processor/testbench and the SDRAM controller.

##### Command Channel (Host → Controller)

| Signal | Width | Direction | Description |
|------|------:|:---------:|-------------|
| `cmd_valid` | 1 | In | Asserted by the host to indicate a valid memory command. |
| `cmd_write` | 1 | In | Command type: `1` = WRITE, `0` = READ. |
| `cmd_addr`  | `ROW_BITS+COL_BITS+BANK_BITS` | In | Linear memory address, internally decoded into **bank**, **row**, and **column** fields. |
| `cmd_wdata` | 16 | In | Write data for WRITE commands. |
| `cmd_ready` | 1 | Out | Indicates that the controller can accept a new command in the current cycle. |

**Handshake rule**
- A command is accepted when **`cmd_valid && cmd_ready`** is high on a rising clock edge.
- Commands are accepted **only in the `IDLE` state** and when no refresh operation is pending.
- Input signals are internally registered to avoid race conditions between host and controller.


##### Response Channel (Controller → Host)

| Signal | Width | Direction | Description |
|------|------:|:---------:|-------------|
| `rsp_valid` | 1 | Out | Asserted when read data is valid. |
| `rsp_rdata` | 16 | Out | Read data returned from SDRAM. |
| `rsp_ready` | 1 | In | Asserted by the host to accept the read response (backpressure support). |

**Response behavior**
- `rsp_valid` is asserted **only for READ commands**.
- Read data is latched internally before asserting `rsp_valid`.
- If `rsp_ready = 0`, the controller **holds `rsp_valid` and `rsp_rdata` stable** until the host asserts `rsp_ready = 1`.
- The read transaction completes when **`rsp_valid && rsp_ready`** is observed on a rising clock edge.

This mechanism allows the host to stall the controller if it is temporarily unable
to accept read data.


#### B) SDRAM Device Interface

This interface directly connects the controller to an external SDR SDRAM device.

| Signal | Width | Direction | Description |
|------|------:|:---------:|-------------|
| `sd_clk` | 1 | Out | SDRAM clock (directly driven by the controller clock). |
| `sd_cke` | 1 | Out | Clock enable for SDRAM. |
| `sd_cs_n` | 1 | Out | Chip select (active low). |
| `sd_ras_n` | 1 | Out | Row Address Strobe (active low). |
| `sd_cas_n` | 1 | Out | Column Address Strobe (active low). |
| `sd_we_n`  | 1 | Out | Write Enable (active low). |
| `sd_ba` | `BANK_BITS` | Out | Bank address. |
| `sd_addr` | 13 | Out | Row/column address bus. Bit `A10` is used for **auto-precharge**. |
| `sd_dq` | 16 | Inout | Bidirectional data bus. Driven by the controller during WRITE and sampled during READ. |
| `sd_dqm` | 2 | Out | Data mask (fixed to `00` in this design). |

**SDRAM command encoding**
The controller generates SDRAM commands using `{RAS_n, CAS_n, WE_n}`:
- `ACTIVE`, `READ`, `WRITE`, `PRECHARGE`, `REFRESH`, `MODE REGISTER SET`, and `NOP`.

**Data bus control**
- During WRITE operations, the controller drives `sd_dq` and asserts internal output-enable.
- During READ operations, `sd_dq` is tri-stated by the controller and sampled after CAS latency.
- At all other times, the bus remains in high-impedance state.


#### D) Debug and Status Interface

These signals are provided for **verification and debugging** purposes.

| Signal | Width | Direction | Description |
|------|------:|:---------:|-------------|
| `state_out` | 5 | Out | Encodes the current FSM state of the controller. |
| `error_flag` | 1 | Out | Indicates abnormal conditions such as timeouts or illegal states. |

`state_out` is primarily used by the testbench to:
- Detect when the controller returns to `IDLE`
- Synchronize test sequences
- Diagnose incorrect FSM transitions

---

### 1.3 Functional Description

#### A) SDRAM Initialization Sequence
After reset, the controller performs the standard SDRAM initialization flow:

1. **CKE low delay** (≈100 µs, `T_INIT_100US`)
2. **PRECHARGE ALL** (`T_RP`)
3. **Two AUTO REFRESH commands** (`T_RFC`)
4. **MODE REGISTER SET** (programs CAS latency `CL`, burst length = 1)
5. Transition to **IDLE** state

---

#### B) READ / WRITE Operation (Single-Beat)

**Command acceptance**
- Commands are accepted only in `IDLE`
- Refresh requests have priority over host commands
- Row-hit optimization:
  - If the requested bank/row is already active → direct READ/WRITE
  - Otherwise → issue `ACTIVE` and wait `tRCD`

**READ flow**
1. Issue `READ` command with `A10 = 1` (auto-precharge)
2. Wait **CAS latency (CL)**
3. Sample `sd_dq` and assert `rsp_valid`
4. Hold `rsp_valid` and `rsp_rdata` until `rsp_ready = 1`
5. Wait recovery time and return to `IDLE`

**WRITE flow**
1. Issue `WRITE` command with `A10 = 1`
2. Drive `sd_dq` with `cmd_wdata`
3. Wait write recovery (`T_WR + T_RP`)
4. Return to `IDLE`

---

#### C) Refresh Handling
- Internal refresh counter generates `refresh_pending`
- When pending and in `IDLE`, an `AUTO REFRESH` command is issued
- Refresh timing uses `T_RFC`
- Refresh can be effectively disabled in simulation by setting a large `T_REF_INT`

---

### 1.4 Design Notes
- Tri-state data bus implementation:  
  `sd_dq = dq_oe ? dq_out : 'Z`
- Input command signals are **registered** to avoid race conditions
- Handshake-correct READ response with backpressure support
- Intended for **functional correctness and clarity**, not peak performance

---

## 2. Testbench (`tb_sdram_ctrl.v`)

### 2.1 Overview

The testbench verifies the controller using:
- A cycle-accurate **behavioral SDRAM model** (`sdram_model.v`)
- Self-checking test cases

The SDRAM model includes:
- Bank/row tracking
- CAS latency pipeline
- Auto-precharge handling
- Reduced memory size for fast simulation

---

### 2.2 Test Cases

#### Test 1 – Single Write & Read
- Write one word to memory
- Read it back
- Verify data integrity

#### Test 2 – Multiple Sequential Writes
- Perform multiple writes to consecutive addresses
- Ensure all write operations complete successfully

#### Test 3 – Multiple Sequential Reads
- Read back data written in Test 2
- Verify correct data ordering

#### Test 4 – Different Bank Access
- Access multiple banks
- Verify correct bank decoding and isolation

#### Test 5 – CAS Latency Timing Check
- Measure time between READ command on SDRAM bus and `rsp_valid`
- Verify delay matches configured CAS latency

#### Test 6 – Back-to-Back Transactions
- Perform consecutive write and read operations
- Ensure no data corruption or protocol violation

#### Test 7 – Response Hold (Backpressure)
- Assert `rsp_ready = 0`
- Verify `rsp_valid` and `rsp_rdata` are held stable
- Release `rsp_ready` and complete the transaction

---

## 3. Intended Use

This project is suitable for:
- FPGA front-end RTL portfolio
- Memory controller design practice
- Verification and timing-aware FSM design exercises
- Academic coursework and capstone projects

---

## 4. Notes

- Burst access, bank interleaving, and advanced scheduling are **not implemented**
- Timing is simplified but SDRAM-correct for single-beat accesses
- The design prioritizes **readability and correctness**

---

## Author
Developed as an RTL design and verification exercise for SDRAM controllers.
