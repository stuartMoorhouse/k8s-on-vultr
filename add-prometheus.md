# add kube state metrics
 helm repo add prometheus-community https://prometheus-community.github.io/helm-charts                  
 helm install kube-state-metrics prometheus-community/kube-state-metrics    

# add prometheus
kubectl apply -f prometheus/prometheus-config-map.yml
kubectl apply -f prometheus/prometheus-deployment.yml
kubectl apply -f prometheus/prometheus-service.yml

kubectl port-forward svc/prometheus 9090:9090 &


