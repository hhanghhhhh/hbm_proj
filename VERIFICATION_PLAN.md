# FPGA Communication Verification Plan

## 1. Purpose

Define the minimum verification items for the FPGA communication framework.

Verification focuses on:

- Frame Parser correctness;
- request/response transaction control;
- RAM access timing;
- error handling;
- TX handshake behavior;
- timeout recovery.

---

## 2. Interface Timing Rules

All transaction valid signals are pulse signals:

```text
frame_valid : 1 clock pulse
req_valid   : 1 clock pulse
rsp_valid   : 1 clock pulse
tx_done     : 1 clock pulse
```

Payload RAM uses synchronous read:

```text
payload_rd_addr
        |
        | 1 clock delay
        v
payload_rd_data
```

---

## 3. Frame Parser Tests

Required cases:

- Correct SOF detection;
- Continuous SOF pattern and resynchronization;
- Valid frame CRC pass;
- CRC error frame discard;
- Invalid LENGTH discard;
- Payload length = 0;
- Payload length = 1;
- Payload length = maximum supported size;
- Receive timeout during incomplete frame.

Expected behavior:

- Only CRC verified frames generate `frame_valid`;
- Invalid frames are silently discarded;
- No error response is generated for untrusted frames.

---

## 4. Dispatcher and Transaction Tests

Required cases:

- Known CMD routing;
- Unknown CMD generates error request;
- `req_valid` only pulses once per transaction;
- Current transaction blocks new requests until completion;
- Timeout generates transaction abort/reset notification.

---

## 5. Response Path Tests

Required cases:

- Normal response generation;
- Error response generation;
- Response Payload first byte is STATUS;
- Response LENGTH is at least 1 for normal/error responses;
- ADDR/CMD/SEQ are copied from request context;
- Multiple response sources do not conflict.

---

## 6. TX Frame Builder Tests

Required cases:

- Response RAM write then transmit;
- Zero payload response support;
- `tx_ready` random stall behavior;
- Byte stream remains stable while `tx_ready=0`;
- CRC generation matches expected value;
- `tx_done` generated after last CRC byte handshake.

---

## 7. Timeout and Recovery Tests

Required cases:

- RX timeout resets incomplete frame;
- Transaction timeout clears current transaction state;
- Following valid request works after abort;
- TX stall timeout recovery.

---

## 8. Protocol Tests

Required cases:

- SEQ matching between request and response;
- Verify that SEQ is only used for request/response matching;
- No automatic duplicate command handling is required.

---

## 9. Future Extension Tests

Reserved for:

- Large configuration transfer;
- Firmware upgrade flow;
- Snapshot/batch read;
- Reset during RX/business/TX processing.
