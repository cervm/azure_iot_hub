These are public test credentials for a loopback TLS peer, never for deployment.
The leaf covers `localhost` and `127.0.0.1` and expires **1 October 2027**.
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
