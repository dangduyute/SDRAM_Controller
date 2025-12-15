# SDRAM Controller – RTL & Testbench Verification

This repository contains a **Verilog-based SDRAM controller**, a **behavioral SDRAM model**, and a **self-checking testbench**.  
The project is intended for **RTL design practice**, **memory controller verification**, and **FPGA front-end portfolio projects**.

---

## 1. RTL Design (`sdram_ctrl.v`)

### 1.1 Overview

The RTL implements a **single-data-rate (SDR) SDRAM controller** with a **16-bit data bus**, based on a **finite state machine (FSM)** and parameterized timing control.

The design focuses on:
- Correct SDRAM **initialization sequence**
- **Single-beat READ/WRITE** transactions
- **Auto-precharge** support
- **CAS latency (CL) awareness**
- Clean **host/controller handshake**
- Cycle-accurate timing for simulation and learning purposes

All critical SDRAM timing parameters are configurable through Verilog parameters, making the controller easy to adapt for different SDRAM devices or simulation requirements.

---

### 1.2 Interfaces

#### Host Command Interface

| Signal | Direction | Description |
|------|-----------|-------------|
| `cmd_valid` | In | Host asserts a valid command |
| `cmd_write` | In | `1` = WRITE, `0` = READ |
| `cmd_addr`  | In | Combined address (Bank + Column + Row) |
| `cmd_wdata` | In | 16-bit write data |
| `cmd_ready` | Out | Controller ready to accept a new command |
| `rsp_valid` | Out | Read response is valid |
| `rsp_rdata` | Out | 16-bit read data |
| `rsp_ready` | In | Host ready to accept read data (backpressure) |

#### SDRAM Interface

| Signal | Description |
|------|-------------|
| `sd_clk` | SDRAM clock |
| `sd_cke` | Clock enable |
| `sd_cs_n` | Chip select (active low) |
| `sd_ras_n` | Row address strobe |
| `sd_cas_n` | Column address strobe |
| `sd_we_n` | Write enable |
| `sd_ba` | Bank address |
| `sd_addr` | Address bus (row/column + A10 auto-precharge) |
| `sd_dq` | 16-bit bidirectional data bus |
| `sd_dqm` | Data mask |

#### Debug / Status

| Signal | Description |
|------|-------------|
| `state_out` | Current FSM state (for debug/verification) |
| `error_flag` | Error/timeout indication |

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
- Automatic waveform generation (XSIM/WDB or VCD)
- Time-outs to detect deadlocks

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
