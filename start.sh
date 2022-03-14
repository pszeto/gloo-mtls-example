#/bin/sh
alias k=kubectl 
echo "Generate the a server certificate and it's corresponding private key"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout server.key -out server.crt -subj "/C=US/ST=MA/L=Boston/O=SOLO/OU=CSE/CN=example.com"
echo ""
echo "Generate the a server certificate and it's corresponding private key"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout client.key -out client.crt -subj "/C=US/ST=MA/L=Boston/O=SOLO/OU=CSE/CN=example.com"
echo ""
echo "Generating generic nginx-certs"
k create secret generic nginx-certs --from-file=client.crt --from-file=server.crt --from-file=server.key
echo ""
echo "Deploying nginx"
k apply -f ./nginx.yaml
kubectl wait pod -n default --all --for=condition=Ready --timeout=120s
echo ""
NGINX_IP=""
while [ -z $NGINX_IP ]; do
  echo "Waiting for nginx loadbalancer..."
  NGINX_IP=$(kubectl get svc nginx --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}")
  [ -z "$NGINX_IP" ] && sleep 10
done
echo 'nginx loadbalancer ready:' && echo $NGINX_IP

echo "============================================================TEST 1 Start============================================================"
echo "Curling NGINX without client certificates"
echo "curl -L https://${NGINX_IP}/get -v -k"
curl -L https://${NGINX_IP}/get -v -k
echo "============================================================TEST 1 End=============================================================="

echo "============================================================TEST 2 Start============================================================"
echo "Curling NGINX with client certificates"
echo "curl -L https://${NGINX_IP}/get -v -k --cacert server.crt --key client.key --cert client.crt"
curl -L https://${NGINX_IP}/get -v -k --cacert server.crt --key client.key --cert client.crt
echo "============================================================TEST 2 End=============================================================="
echo ""
PROXY_IP=""
while [ -z $PROXY_IP ]; do
  echo "Waiting for Gateway-Proxy loadbalancer..."
  PROXY_IP=$(kubectl get svc -n gloo-system gateway-proxy --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}")
  [ -z "$PROXY_IP" ] && sleep 10
done
echo 'Gateway-Proxy ready:' && echo $PROXY_IP
echo ""
echo "Checking upstream has been discovered"
NGINX_UPSTREAM_STATUS=$(k get upstreams -n gloo-system default-nginx-443 -o jsonpath='{.status.statuses.gloo-system.state}')
while [[ $NGINX_UPSTREAM_STATUS != "1" ]]
do
    echo "default-nginx-443 has not been discovered"
    sleep 10
    NGINX_UPSTREAM_STATUS=$(k get upstreams -n gloo-system default-nginx-443 -o jsonpath='{.status.statuses.gloo-system.state}')
done
echo "default-nginx-443 has been discovered"
echo ""
echo "Creating Virtual Service with nginx route"
glooctl add route --path-exact /nginx-secure  --dest-name default-nginx-443 --prefix-rewrite /
k patch vs -n gloo-system default --type='merge' -p '{"spec":{"virtualHost":{"routes":[{"matchers":[{"prefix":"/nginx-secure"}],"routeAction":{"single":{"upstream":{"name":"default-nginx-443","namespace":"gloo-system"}}},"options":{"regexRewrite":{"pattern":{"regex":"/nginx-secure/"},"substitution":"/"}}}]}}}'
VS_STATUS=$(k get vs -n gloo-system default -o jsonpath='{.status.statuses.gloo-system.state}')
while [[ $VS_STATUS != "1" ]]
do
    echo "Virtual Service default has not been processed"
    sleep 10
    VS_STATUS=$(k get vs -n gloo-system default -o jsonpath='{.status.statuses.gloo-system.state}')
done
echo "Virtual Service default has been processed"
echo "Generating upstream tls secret"
k create secret tls nginx-tls-noca --cert=client.crt --key=client.key
k patch -n gloo-system vs default --type='merge' -p '{"spec":{"sslConfig":{"secretRef":{"name":"nginx-tls-noca","namespace":"default"}}}}'
echo "Waiting 15 seconds"
sleep 15
echo "============================================================TEST 3 Start============================================================"
echo "Curling Gateway-Proxy without MTLS enabled on upstream"
echo "curl -L https://${PROXY_IP}/nginx-secure/get -v -k"
curl -L https://${PROXY_IP}/nginx-secure/get -v -k
echo "============================================================TEST 3 End=============================================================="
echo ""

echo "Patching default-nginx-443 upstream for mtls"
NGINX_UPSTREAM_STATUS=$(k get upstreams -n gloo-system default-nginx-443 -o jsonpath='{.status.statuses.gloo-system.state}')
if [ $NGINX_UPSTREAM_STATUS == "1" ]
then
    echo "Patch nginx secure upstream"
    k patch -n gloo-system upstream default-nginx-443 --type='merge' -p '{"spec":{"sslConfig":{"secretRef":{"name":"nginx-tls-noca","namespace":"default"}}}}'
fi
echo "Waiting 15 seconds"
sleep 15
echo "============================================================TEST 3 Start============================================================"
echo "Curling Gateway-Proxy WITH MTLS enabled on upstream"
echo "curl -L https://${PROXY_IP}/nginx-secure/get -v -k"
curl -L https://${PROXY_IP}/nginx-secure/get -v -k
echo "============================================================TEST 3 End=============================================================="
echo ""
