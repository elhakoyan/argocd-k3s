#!/bin/bash
source logger.sh 

show_help() {
  cat << EOF
NAME
  Secret manager - help you create, update and delete encrypted kubernetes secrets
SYNOPSIS
  ./secret-manager.sh -e (dev,stage,qa,prod) -n your-namespace -s secret-name -o (create,delete,update)

  ./secret-manager.sh -e dev -n your-namespace -s secret-name -o create --from-literal aa=11 --from-literal aaa=bbb --from-file ~/keys/example.pem

  ./secret-manager.sh -e dev -n your-namespace -s secret-name -o create --from-literal aa=11 --from-file aaa=bbb.txt --from-file new.pem=~/keys/example.pem

  ./secret-manager.sh -e dev -n your-namespace -s secret-name -o delete

  ./secret-manager.sh -e dev -n your-namespace -s secret-name -o update  --from-literal aa=223 --from-literal bbt=45 -d aaa --from-file ~/new_keys/new.pem

  ./secret-manager.sh -e dev -n your-namespace -s test-tls --secret-type tls --cert-path ./example.crt --key-path ./example.key -o create

  ./secret-manager.sh -e dev -n your-namespace -s new-image-register --secret-type docker -o create --docker-username user1 --docker-password 1234 --docker-server gcr.io --docker-email test@example.com
DESCRIPTION
  This script to help manage secrets which can be pushed to the repository and deployed by argocd.
Requirements: 
  kubectl command line utility             - https://kubernetes.io/docs/reference/kubectl/
  yq tool to be installed and version >= 4 - https://mikefarah.gitbook.io/yq/
  kubeseal command line utility            - https://github.com/bitnami-labs/sealed-secrets
OPTIONS
-h|--help                Show help
-e|--env                 Environment (dev, stage, qa, prod): Required
-n|--namespace           Namespace where to put or update secret: Required
-s|--secret-name         The secret name which is going to be created, updated or deleted: Required
-o|--operation           Operation like fetch-seal-key, create, delete or update: Required
--from-file              Key files can be specified using their file path, in which case a default name will be 
                         given to them, or optionally with a name and file path, in which case the given name will be used.
                         Specifying a directory will iterate each named file in the directory that is a valid secret key
                         --from-file [key=]source
--from-literal           Specify a key and literal value to insert in secret 
                         (i.e. mykey=somevalue) [--from-literal key1=value1]

--secret-type            In kubernetes there are 3 secret types
                          1. generic (Default)
                          2. tls
                          3. docker

--docker-email           Email for Docker registry (user for docker type of secret)
--docker-password        Password for Docker registry authentication (user for docker type of secret)
--docker-username        Server location for Docker registry (user for docker type of secret)
--docker-server          Username for Docker registry authentication (user for docker type of secret)

--cert-path              Certificate path for tls type of secret
--key-path               Key path for tls type of secret

-d|--fields-to-delete    Mention the secret fields that are going to be deleted on the update phase
EOF
}

function confirmation() {
  read -r -p "$1 [y/N] " response
  case "$response" in
      [yY][eE][sS]|[yY]) 
          echo
          ;;
      *)
          error "Check your arguments and try again"
          exit 0
          ;;
  esac
}

ROOT_PATH=$(git rev-parse --show-toplevel)

POSITIONAL_ARGS=()

if [ $# -eq 0 ]
  then
    error "No arguments supplied, use -h to show options"
    exit 1
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    -e|--env)
      ENV="$2"
      if [[ "${ENV}" != "dev" && "${ENV}" != "stage" && "${ENV}" != "qa" && "${ENV}" != "prod" ]]; then
        error "Please mention correct environment value (dev stage qa prod)"
        exit 1
      else
        shift # past argument
        shift # past value
      fi
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift # past argument
      shift # past value
      ;;
    -s|--secret-name)
      SECRET_NAME="$2"
      shift # past value
      shift # past argument
      ;;
    -o|--operation)
      OPERATION="$2"
      if [[ "${OPERATION}" != "create" && "${OPERATION}" != "update" && "${OPERATION}" != "delete" && "${OPERATION}" != "fetch-seal-key" ]]; then
        error "Please mention correct operation value (create update delete)"
        exit 1
      else
        shift # past argument
        shift # past value
      fi
      ;;
    --from-file)
      FROM_FILE+=("--from-file=$2")
      shift # past value
      shift # past argument
      ;;
    --from-literal)
      FROM_LIERAL+=("--from-literal=$2")
      shift # past value
      shift # past argument
      ;;
    --docker-email)
      DOCKER_EMAIL="$2"
      shift # past value
      shift # past argument
      ;;
    --docker-password)
      DOCKER_PASSWORD="$2"
      shift # past value
      shift # past argument
      ;;
    --docker-username)
      DOCKER_USERNAME="$2"
      shift # past value
      shift # past argument
      ;;
    --docker-server)
      DOCKER_SERVER="$2"
      shift # past value
      shift # past argument
      ;;
    --cert-path)
      CERT_PATH="$2"
      shift # past value
      shift # past argument
      ;;
    --key-path)
      KEY_PATH="$2"
      shift # past value
      shift # past argument
      ;;
    --secret-type)
      SECRET_TYPE="$2"
      shift # past value
      shift # past argument
      ;;
    -d|--fields-to-delete)
      FIELDS_TO_DELETE+=("$2")
      shift # past value
      shift # past argument
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*|--*)
      error "Unknown option $1"
      show_help
      break
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

if [[ -z "${SECRET_NAME}" && "${OPERATION}" != "fetch-seal-key" ]]; then
  error "-s|--secret-name parameter is required"
  exit 1
fi
if [[ -z "${ENV}" ]]; then
  error "-e|--env parameter is required"
  exit 1
fi
if [[ -z "${NAMESPACE}" &&  "${OPERATION}" != "fetch-seal-key" ]]; then
  error "-n|--namespace parameter is required"
  exit 1
fi
if [ -z "${OPERATION}" ]; then
  error "-o|--operation parameter is required"
  exit 1
fi

SECRET_DIR=${ROOT_PATH}/manifests/environments/${ENV}/secrets
SECRET_PATH="${SECRET_DIR}/${NAMESPACE}-${SECRET_NAME}".yaml

case $OPERATION in
fetch-seal-key)
  kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --fetch-cert > keys/"${ENV}"/seal.pem
;;
create)
  case "$SECRET_TYPE" in
    "tls")
        if [[ -z "${KEY_PATH}" || -z "${CERT_PATH}" ]]; then
          error "--key-path and --cert-path is required on create tls type secret."
          exit 1
        fi
        NEW_SECRET=$(kubectl create secret tls -n "${NAMESPACE}" "${SECRET_NAME}" --key="${KEY_PATH}" --cert="${CERT_PATH}" --dry-run=client -o yaml)
        ;;
    "docker")
        NEW_SECRET=$(kubectl create secret docker-registry -n "${NAMESPACE}" "${SECRET_NAME}" --docker-server="${DOCKER_SERVER}" --docker-username="${DOCKER_USERNAME}" --docker-password="${DOCKER_PASSWORD}" --docker-email="${DOCKER_EMAIL}" --dry-run=client -o yaml)        
        ;;
    *)
        if [[ -z "${FROM_FILE}" && -z "${FROM_LIERAL}" ]]; then
          error "--from-file or --from-literal at least one parameter is required on create stage."
          exit 1
        fi
        NEW_SECRET=$(kubectl create secret generic -n "${NAMESPACE}" "${SECRET_NAME}" "${FROM_FILE[@]}" "${FROM_LIERAL[@]}" --dry-run=client -o yaml)
        ;;
    esac
  
  warn "You are going to create the following secret \n"
  info "${NEW_SECRET}\n"
  confirmation "Is it looks good?"
  echo "${NEW_SECRET}" | kubeseal \
      --controller-name=sealed-secrets \
      --controller-namespace=default \
      --format yaml --cert ${ROOT_PATH}/keys/${ENV}/seal.pem  > ${SECRET_PATH}
  success "The encrypted secret saved in ${SECRET_PATH} file"
  warn "To create a secret push your change to the repositery master branch and argocd will take care of it"
  ;;
delete)
  if [[ ! -f ${SECRET_PATH} ]]; then
   error "Seems secret do not exist or created without argocd check the secret name again!"
   exit 1
  fi
  warn "Deleting the secret ${SECRET_NAME}"
  confirmation "Do you want delete the ${SECRET_NAME} secret?"
  rm -f ${SECRET_PATH}
  success "The encrypted secret file ${SECRET_PATH} deleted"
  warn "To delete a secret push your change to the repositery master branch and argocd will take care of it"
  ;;
update)
  if [[ -z "${FROM_FILE}" && -z "${FROM_LIERAL}" &&  -z "${FIELDS_TO_DELETE}" ]]; then
    error "--from-file, --from-literal or -d|--fields-to-delete at least one parameter is required on update stage."
    exit 1
  fi
  if [[ ! -f ${SECRET_PATH} ]]; then
   error "Seems secret do not exist or it can be created without argocd!"
   exit 1
  fi
  confirmation "Do you want update the ${SECRET_NAME} secret?"
  NEW_SECRET=$(kubectl create secret generic -n "${NAMESPACE}" "${SECRET_NAME}" "${FROM_FILE[@]}" "${FROM_LIERAL[@]}" --dry-run=client -o yaml)
  echo "${NEW_SECRET}" | kubeseal \
      --controller-name=sealed-secrets \
      --controller-namespace=default \
      --allow-empty-data \
      --format yaml --cert ${ROOT_PATH}/keys/${ENV}/seal.pem  > ${SECRET_DIR}/new-"${SECRET_NAME}".yaml
  yq -i eval-all '. as $item ireduce ({}; . * $item )' ${SECRET_PATH} ${SECRET_DIR}/new-"${SECRET_NAME}".yaml
  rm -r ${SECRET_DIR}/new-"${SECRET_NAME}".yaml
  for filed in "${FIELDS_TO_DELETE[@]}"
  do
    yq -i "del(.spec.encryptedData.$filed)" ${SECRET_PATH}
  done
  success "The encrypted secret file ${SECRET_PATH} updated"
  warn "To update a secret push your change to the repositery master branch and argocd will take care of it"
  ;;
*)
  error "PROVIDE CORRECT OPERATION";;
esac
