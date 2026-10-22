# Optional s packet support

A field named `s` has no universal encryption format. This optional codec supports an explicit legacy envelope only:

- Type 1: a leading byte `1`, followed by plaintext UTF-8.
- Type 2: byte `2`, a four-byte little-endian key length, the AES key, then AES-CBC / PKCS7 data.
- Type 3: byte `3`, a four-byte little-endian wrapped-key length, RSA PKCS#1 v1.5 wrapped AES key, then AES-CBC / PKCS7 data.

The legacy format uses a 16-byte AES key as its IV. This is compatibility code, not a recommended design for new cryptographic protocols. No service-specific keys are supplied. Encryption requires an explicitly imported RSA public key; type 3 decryption requires the matching private key. Keys remain in memory for this run.

For a separately hosted decoder, enter its URL in the s editor. The optional service adapter sends a JSON POST body with `is_new` (`old` or `new`) and `encrpt_params` (selected s), and expects `result_code: 200` with plaintext in `data`. No endpoint is configured by default. The protocol is not suitable for arbitrary services; use only a trusted service you control or have permission to use. HTTPS is recommended.
