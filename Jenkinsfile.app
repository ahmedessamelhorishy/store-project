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
          import_if_missing() {
            repo=$1
            tag=$2
            source=$3

            if ! az acr repository show-tags --name "$ACR_NAME" --repository "$repo" | grep -q "$tag"; then
              echo "Importing $repo:$tag from $source"
              az acr import --name "$ACR_NAME" \
                --source "$source" \
                --image "$repo:$tag" \
                --image "$repo:latest"
            else
              echo "$repo:$tag already exists. Skipping import."
            fi
          }

          import_if_missing rabbitmq 3.12-management docker.io/library/rabbitmq:3.12-management
          import_if_missing mongo 6 docker.io/library/mongo:6
          import_if_missing product-service latest ghcr.io/azure-samples/aks-store-demo/product-service:latest
          import_if_missing virtual-customer latest ghcr.io/azure-samples/aks-store-demo/virtual-customer:latest
          import_if_missing virtual-worker latest ghcr.io/azure-samples/aks-store-demo/virtual-worker:latest
        '''
      }
    }

    stage('First-time deploy check') {
      when { expression { env.COMMIT_MSG.contains('[app]') || env.COMMIT_MSG.contains('[seed]') } }
      steps {
        sh '''
          echo "Applying aks-store-all-in-one.yaml to ensure all workloads exist..."
          kubectl apply -n "${K8S_NAMESPACE}" -f aks-store-all-in-one.yaml
        '''
      }
    }

    stage('Update third-party workloads') {
      when { expression { env.COMMIT_MSG.contains('[seed]') } }
      steps {
        sh '''
          kubectl -n "${K8S_NAMESPACE}" set image deploy/product-service \
            product-service="${ACR_LOGIN}/product-service:latest" || true

          kubectl -n "${K8S_NAMESPACE}" set image deploy/virtual-customer \
            virtual-customer="${ACR_LOGIN}/virtual-customer:latest" || true

          kubectl -n "${K8S_NAMESPACE}" set image deploy/virtual-worker \
            virtual-worker="${ACR_LOGIN}/virtual-worker:latest" || true

          kubectl -n "${K8S_NAMESPACE}" set image statefulset/rabbitmq \
            rabbitmq="${ACR_LOGIN}/rabbitmq:latest" || true
          kubectl -n "${K8S_NAMESPACE}" rollout restart statefulset/rabbitmq || true

          kubectl -n "${K8S_NAMESPACE}" set image statefulset/mongodb \
            mongodb="${ACR_LOGIN}/mongo:latest" || true
          kubectl -n "${K8S_NAMESPACE}" rollout restart statefulset/mongodb || true

          kubectl -n "${K8S_NAMESPACE}" rollout status statefulset/rabbitmq || true
          kubectl -n "${K8S_NAMESPACE}" rollout status statefulset/mongodb || true
          kubectl -n "${K8S_NAMESPACE}" rollout status deploy/product-service || true
          kubectl -n "${K8S_NAMESPACE}" rollout status deploy/virtual-customer || true
          kubectl -n "${K8S_NAMESPACE}" rollout status deploy/virtual-worker || true
        '''
      }
    }

    stage('Build first-party images with Docker then push to ACR') {
      when { expression { env.COMMIT_MSG.contains('[app]') } }
      steps {
        sh '''
          az acr login --name "$ACR_NAME"

          # Order-service
          docker build -t ${ACR_LOGIN}/order-service:${IMAGE_TAG} ./src/order-service
          docker tag ${ACR_LOGIN}/order-service:${IMAGE_TAG} ${ACR_LOGIN}/order-service:latest
          docker push ${ACR_LOGIN}/order-service:${IMAGE_TAG}
          docker push ${ACR_LOGIN}/order-service:latest

          # Store-front
          docker build -t ${ACR_LOGIN}/store-front:${IMAGE_TAG} ./src/store-front
          docker tag ${ACR_LOGIN}/store-front:${IMAGE_TAG} ${ACR_LOGIN}/store-front:latest
          docker push ${ACR_LOGIN}/store-front:${IMAGE_TAG}
          docker push ${ACR_LOGIN}/store-front:latest

          # Store-admin
          docker build -t ${ACR_LOGIN}/store-admin:${IMAGE_TAG} ./src/store-admin
          docker tag ${ACR_LOGIN}/store-admin:${IMAGE_TAG} ${ACR_LOGIN}/store-admin:latest
          docker push ${ACR_LOGIN}/store-admin:${IMAGE_TAG}
          docker push ${ACR_LOGIN}/store-admin:latest

          # Makeline-service
          docker build -t ${ACR_LOGIN}/makeline-service:${IMAGE_TAG} ./src/makeline-service
          docker tag ${ACR_LOGIN}/makeline-service:${IMAGE_TAG} ${ACR_LOGIN}/makeline-service:latest
          docker push ${ACR_LOGIN}/makeline-service:${IMAGE_TAG}
          docker push ${ACR_LOGIN}/makeline-service:latest
        '''
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