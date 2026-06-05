kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > kube-ca.crt
vault write auth/kubernetes/config kubernetes_host="https://192.168.1.180:6443" kubernetes_ca_cert=@kube-ca.crt token_reviewer_jwt="$(kubectl get secret vault-auth -n vault-secrets-operator -o jsonpath='{.data.token}' | base64 -d)"
rm kube-ca.crt
