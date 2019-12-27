# eks-orb
Orb for installing the tools to interact with Amazon Elastic Container Service for Kubernetes (EKS) from within a
CircleCI build job.

## View in the orb registry
See the [eks-orb in the registry](https://circleci.com/orbs/registry/orb/tiendanube/eks)
for more the full details of jobs, commands, and executors available in this
orb.

## Setup required to use this orb
The following **required** dependencies must be configured in CircleCI in order to use this orb:

* **AWS_ACCESS_KEY_ID** - environment variable for AWS login
* **AWS_SECRET_ACCESS_KEY** - environment variable for AWS login

For more information on how to properly set up environment variables on CircleCI, read the docs:
[environment-variable-in-a-project](https://circleci.com/docs/2.0/env-vars/#setting-an-environment-variable-in-a-project)

## Sample use in CircleCI config.yml

- Deploy

```yaml
version: 2.1
orbs:
  eks: tiendanube/eks@1.1.0
workflows:
  deploy:
    jobs:
      - eks/deploy:
          cluster-name: cluster-name
          region: region
          steps:
            - run:
                command: |
                  kubectl apply -f bundle.yml
                  kubectl apply -f deployment.yml
```

- Helm Deploy

```yaml
version: 2.1
orbs:
  eks: tiendanube/eks@1.1.0
workflows:
  deploy:
    jobs:
      - eks/helm-deploy:
          cluster-name: cluster-name
          region: aws-region
          release-name: release-name
          values-file: values.yaml
          namespace: default
          chart: stable/chart-to-be-installed
          chart-version: latest
          image-tag: ${CIRCLE_SHA1:0:7}
```

- AWS with Authenticator to Kubernetes

```yaml
version: 2.1

orbs:
  eks: tiendanube/eks@1.1.0

workflows:
  deploy:
    jobs:
      - eks/update-kubeconfig-with-authenticator:
          label: my label
          aws-region: aws-region
          cluster-name: cluster-name
          aws-profile: aws-profile
          kubeconfig-file-path: kubeconfig-file-path
          cluster-authentication-role-arn: cluster-authentication-role-arn
          cluster-context-alias: cluster-context-alias
          dry-run: false
          verbose: false
```

- kubectl

```yaml
version: 2.1

orbs:
  eks: tiendanube/eks@1.1.0

workflows:
  deploy:
    jobs:
      - eks/kubectl:
          label: my label
          working_dir: ~/project
          namespace: namespace
          command: command # Available Commands in kubectl
          args: args
```

- Helm Client

```yaml
version: 2.1

orbs:
  eks: tiendanube/eks@1.1.0

workflows:
  deploy:
    jobs:
      - eks/helm-client:
          label: my label
          working_dir: ~/project
          namespace: namespace
          command: command # Available Commands in helm
          args: args
```
- Helmfile Client

Example use of the helmfile [below](#helmfile):

```yaml
version: 2.1

orbs:
  eks: tiendanube/eks@1.1.0

workflows:
  deploy:
    jobs:
      - eks/helmfile-client:
          label: my label
          working_dir: ~/project
          cluster-name: namespace
          env: environment
          command: command # Available Commands in helmfile
          args: args
```
- Free execution of commands 

```yaml
version: 2.1

orbs:
  eks: tiendanube/eks@1.1.0

jobs:
  prepare-deployment:
    steps:
      - run: aws-iam-authenticator version
      - run: aws --version
      - run: kubectl version
      - run: helm version
      - run: helmfile --version
      - run: terraform --version
```

## [helmfile]()

- Example use:

```yaml
  - name: external-dns
    namespace: kube-system
    chart: stable/external-dns
    version: latest
    labels:
      app: external-dns
    values:
      - "helmfiles/external-dns/{{ requiredEnv "EKS_ENV" }}/values.yaml"

{{ if eq (requiredEnv "EKS_ENV") "production" }}
  - name: nginx-ingress
    namespace: kube-system
    chart: stable/nginx-ingress
    version: latest
    labels:
      app: nginx-ingress
    values:
      - "helmfiles/nginx-ingress/{{ requiredEnv "EKS_ENV" }}/external.yaml"

{{ end }}
```