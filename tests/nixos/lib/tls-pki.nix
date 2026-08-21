{
  pkgs,
  serverName,
}:
pkgs.runCommand "nixos-test-tls-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
  mkdir "$out"

  openssl req -x509 -newkey rsa:2048 -nodes \
    -subj /CN=nixos-test-ca \
    -keyout "$out/ca.key" \
    -out "$out/ca.crt" \
    -days 36500

  openssl req -new -newkey rsa:2048 -nodes \
    -subj /CN=${serverName} \
    -addext "subjectAltName=DNS:${serverName}" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "$out/server.key" \
    -out "$out/server.csr"
  openssl x509 -req \
    -in "$out/server.csr" \
    -CA "$out/ca.crt" \
    -CAkey "$out/ca.key" \
    -CAcreateserial \
    -copy_extensions copy \
    -out "$out/server.crt" \
    -days 36500
''
