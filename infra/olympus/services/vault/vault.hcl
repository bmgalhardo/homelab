ui = true
disable_mlock = true

storage "raft" {
  path = "/vault/data"
}

listener "tcp" {
  tls_disable = 1
  address     = "0.0.0.0:8200"
//  address     = "127.0.0.1:8200"
}

listener "tcp" {
  tls_disable   = 0
  tls_cert_file = "/certs/vault.crt"
  tls_key_file  = "/certs/vault.key"
  address       = "0.0.0.0:8201"
}

api_addr     = "https://vault.bgalhardo.com"
cluster_addr = "http://127.0.0.1:8202"
// log_level    = "debug"
