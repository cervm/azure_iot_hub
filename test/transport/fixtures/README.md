These are public test credentials for a loopback TLS peer, never for deployment.
The server leaf covers `localhost` and `127.0.0.1` and expires **1 October 2027**.
Tests explicitly trust `ca-cert.pem`; production uses Dart's default roots.
The CA expires in 2040. Keep the leaf short-lived: macOS rejected a 20-year leaf
even with this CA explicitly trusted.

Regenerate from this directory using OpenSSL (the CA signing key is disposable):

```sh
openssl req -x509 -newkey rsa:2048 -noenc \
  -keyout ca-key.pem -out ca-cert.pem -subj '/CN=Azure Dart SDK Test CA' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' -days 3650
openssl req -new -newkey rsa:2048 -noenc -keyout localhost-key.pem \
  -out localhost.csr -subj '/CN=localhost'
cat > leaf.cnf <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF
openssl x509 -req -in localhost.csr -CA ca-cert.pem -CAkey ca-key.pem \
  -set_serial 1 -out localhost-cert.pem -extfile leaf.cnf -days 365
rm ca-key.pem localhost.csr leaf.cnf
```

The X.509 client fixtures use a separate root and intermediate CA. The device
certificate has subject `CN=device-1`, permits client authentication and expires
**25 October 2027**. `device-chain.pem` contains the device leaf followed by its
intermediate; `device-root-ca.pem` is trusted only by the mutual-TLS test peer.
The CA signing keys are discarded. The device key is public test data.

Regenerate the client fixtures from this directory (OpenSSL 3 or later):

```sh
openssl req -x509 -newkey rsa:2048 -noenc \
  -keyout device-root-key.pem -out device-root-ca.pem \
  -subj '/CN=Azure Dart SDK Client Test CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' -days 3650
openssl req -new -newkey rsa:2048 -noenc \
  -keyout intermediate-key.pem -out intermediate.csr \
  -subj '/CN=Azure Dart SDK Client Test Intermediate'
cat > intermediate.cnf <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
openssl x509 -req -in intermediate.csr -CA device-root-ca.pem \
  -CAkey device-root-key.pem -set_serial 2 -out intermediate.pem \
  -extfile intermediate.cnf -days 1825
openssl req -new -newkey rsa:2048 -noenc \
  -keyout device-key.pem -out device.csr -subj '/CN=device-1'
cat > device.cnf <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
openssl x509 -req -in device.csr -CA intermediate.pem \
  -CAkey intermediate-key.pem -set_serial 3 -out device-cert.pem \
  -extfile device.cnf -days 365
cat device-cert.pem intermediate.pem > device-chain.pem
rm device-root-key.pem intermediate-key.pem intermediate.csr intermediate.cnf \
  intermediate.pem device.csr device.cnf device-cert.pem
```

Update the expiry date above after regeneration. The tests do not load these roots
into the operating system store.
