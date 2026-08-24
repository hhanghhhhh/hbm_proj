# FPGA Communication Protocol

## 1. Frame Format

All command and response messages use the same frame format.

| Field | Size |
|---|---:|
| SOF | 2 Byte |
| ADDR | 1 Byte |
| CMD | 1 Byte |
| SEQ | 1 Byte |
| LENGTH | 2 Byte |
| PAYLOAD | N Byte |
| CRC | 2 Byte |

Frame format:

```
+--------+---------+--------+--------+--------+---------+---------+
| SOF    | ADDR    | CMD    | SEQ    | LENGTH | PAYLOAD | CRC     |
+--------+---------+--------+--------+--------+---------+---------+
| 2 Byte | 1 Byte  | 1 Byte | 1 Byte | 2 Byte | N Byte  | 2 Byte  |
+--------+---------+--------+--------+--------+---------+---------+
```

## 2. Basic Rules

- SOF is fixed as `0x55AA`.
- ADDR is used to identify the target device.
- Request and response use the same frame format.
- Multi-byte data uses big-endian format.
- CRC calculation does not include SOF.
- Maximum LENGTH is 2048 Bytes.

## 3. Design Principles

- Frame parsing should support streaming reception and CRC calculation during data reception.
- CRC verification must complete before applying configuration or executing critical commands.
- Large data transmission uses segmented packets.
- Configuration update and firmware update should support complete verification before commit.
