echo | openssl s_client -connect 192.168.1.180:6443 -showcerts | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ { print }' > kube-ca.crt
vault write auth/kubernetes/config kubernetes_host="https://192.168.1.180:6443" kubernetes_ca_cert=@kube-ca.crt token_reviewer_jwt="$(kubectl get secret vault-auth -n vault-secrets-operator -o jsonpath='{.data.token}' | base64 -d)"
vault read pki_root/cert/ca -format=json | jq -r .data.certificate > ca.crt
kubectl create secret generic vault-ca --from-file=ca.crt -n vault-secrets-operator --dry-run=client -o yaml  | kubectl apply -f -
rm kube-ca.crt ca.crt
