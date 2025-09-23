pipeline {
  agent any

  environment {
    AZURE_SUBSCRIPTION = credentials('azure-subscription')
    AZURE_TENANT       = credentials('azure-tenant')
    ACR_NAME           = 'storeimagesacr'
    ACR_LOGIN          = "storeimagesacr.azurecr.io"
    AKS_RG             = 'aks-acr-rg'
    AKS_NAME           = 'store-aks'
    K8S_NAMESPACE      = 'store-ns'
    IMAGE_TAG          = "jenkins${env.BUILD_NUMBER}"
  }

  options { timestamps() }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.COMMIT_MSG = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
        }
      }
    }

    stage('Azure login + AKS context') {
      when { expression { env.COMMIT_MSG.contains('[app]') || env.COMMIT_MSG.contains('[seed]') } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'store-sp', usernameVariable: 'AZ_CLIENT_ID', passwordVariable: 'AZ_CLIENT_SECRET')]) {
          sh '''
            set -e
            az login --service-principal -u "$AZ_CLIENT_ID" -p "$AZ_CLIENT_SECRET" --tenant "$AZURE_TENANT"
            az account set --subscription "$AZURE_SUBSCRIPTION"
            az aks get-credentials -g "$AKS_RG" -n "$AKS_NAME" --overwrite-existing
            kubectl create ns "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
          '''
        }
      }
    }

    stage('Seed third-party images') {
      when { expression { env.COMMIT_MSG.contains('[seed]') } }
      steps {
        sh '''
          # Dual-tag imports: versioned + latest
          az acr import --name "$ACR_NAME" \
            --source docker.io/library/rabbitmq:3.12-management \
            --image rabbitmq:3.12-management \
            --image rabbitmq:latest

          az acr import --name "$ACR_NAME" \
            --source docker.io/library/mongo:6 \
            --image mongo:6 \
            --image mongo:latest

          az acr import --name "$ACR_NAME" \
            --source ghcr.io/azure-samples/aks-store-demo/product-service:latest \
            --image product-service:latest

          az acr import --name "$ACR_NAME" \
            --source ghcr.io/azure-samples/aks-store-demo/virtual-customer:latest \
            --image virtual-customer:latest

          az acr import --name "$ACR_NAME" \
            --source ghcr.io/azure-samples/aks-store-demo/virtual-worker:latest \
            --image virtual-worker:latest
        '''
      }
    }

    stage('Update third-party workloads') {
      when { expression { env.COMMIT_MSG.contains('[seed]') } }
      steps {
        sh '''
          # Deployments (will pick up latest automatically)
          kubectl -n "${K8S_NAMESPACE}" set image deploy/product-service \
            product-service="${ACR_LOGIN}/product-service:latest" || true

          kubectl -n "${K8S_NAMESPACE}" set image deploy/virtual-customer \
            virtual-customer="${ACR_LOGIN}/virtual-customer:latest" || true

          kubectl -n "${K8S_NAMESPACE}" set image deploy/virtual-worker \
            virtual-worker="${ACR_LOGIN}/virtual-worker:latest" || true

          # StatefulSets (force restart to pick up new digest)
          kubectl -n "${K8S_NAMESPACE}" set image statefulset/rabbitmq \
            rabbitmq="${ACR_LOGIN}/rabbitmq:latest" || true
          kubectl -n "${K8S_NAMESPACE}" rollout restart statefulset/rabbitmq || true

          kubectl -n "${K8S_NAMESPACE}" set image statefulset/mongodb \
            mongodb="${ACR_LOGIN}/mongo:latest" || true
          kubectl -n "${K8S_NAMESPACE}" rollout restart statefulset/mongodb || true

          # Wait for rollouts
          kubectl -n "${K8S_NAMESPACE}" rollout status statefulset/rabbitmq || true
          kubectl -n "${K8S_NAMESPACE}" rollout status statefulset/mongodb || true
          kubectl -n "${K8S_NAMESPACE}" rollout status deploy/product-service || true
          kubectl -n "${K8S_NAMESPACE}" rollout status deploy/virtual-customer || true
          kubectl -n "${K8S_NAMESPACE}" rollout status deploy/virtual-worker || true
        '''
      }
    }

    stage('Build first-party images with ACR Tasks') {
      when { expression { env.COMMIT_MSG.contains('[app]') } }
      steps {
        sh '''
          # Order-service
          az acr build --registry "$ACR_NAME" \
            --image order-service:${IMAGE_TAG} \
            --image order-service:latest \
            ./src/order-service

          # Store-front
          az acr build --registry "$ACR_NAME" \
            --image store-front:${IMAGE_TAG} \
            --image store-front:latest \
            ./src/store-front

          # Store-admin
          az acr build --registry "$ACR_NAME" \
            --image store-admin:${IMAGE_TAG} \
            --image store-admin:latest \
            ./src/store-admin 

          # Makeline-service
          az acr build --registry "$ACR_NAME" \
            --image makeline-service:${IMAGE_TAG} \
            --image makeline-service:latest \
            ./src/makeline-service
        '''
      }
    }

    stage('First-time deploy check') {
      when { expression { env.COMMIT_MSG.contains('[app]') } }
      steps {
        script {
          def exists = sh(script: "kubectl get deploy order-service -n ${K8S_NAMESPACE} --ignore-not-found", returnStatus: true) == 0
          if (!exists) {
            echo "First-time deployment detected. Applying aks-store-all-in-one.yaml..."
            sh '''
              kubectl create ns "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
              kubectl apply -n "${K8S_NAMESPACE}" -f aks-store-all-in-one.yaml
            '''
          } else {
            echo "Deployments already exist; skipping kubectl apply."
          }
        }
      }
    }

    stage('Roll deployments to new images') {
      when { expression { env.COMMIT_MSG.contains('[app]') } }
      steps {
        sh '''
          kubectl -n "${K8S_NAMESPACE}" set image deploy/order-service \
            order-service="${ACR_LOGIN}/order-service:${IMAGE_TAG}" || true

          kubectl -n "${K8S_NAMESPACE}" set image deploy/store-front \
            store-front="${ACR_LOGIN}/store-front:${IMAGE_TAG}" || true

          kubectl -n "${K8S_NAMESPACE}" set image deploy/store-admin \
            store-admin="${ACR_LOGIN}/store-admin:${IMAGE_TAG}" || true

          kubectl -n "${K8S_NAMESPACE}" set image deploy/makeline-service \
            makeline-service="${ACR_LOGIN}/makeline-service:${IMAGE_TAG}" || true
        '''
      }
    }
  }

  post {
    success { echo "Pipeline complete. Tag: ${env.IMAGE_TAG}" }
  }
}
