# EKS Orb
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
  eks: tiendanube/eks@1.3.0
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
  eks: tiendanube/eks@1.3.0
workflows:
  deploy:
    jobs:
      - eks/helm-deploy:
          cluster-name: cluster-name
          region: aws-region
          release-name: release-name
          values-file: values.yaml
          namespace: default
          chart: stable/chart
          chart-version: latest
          image-tag: ${CIRCLE_SHA1:0:7}
          resource-name: deployment
          rollout-status: true
          rollout-status-watch: true
          rollout-status-timeout: 5m
```

- Annotations

```yaml
version: 2.1
orbs:
  eks: tiendanube/eks@1.3.0
workflows:
  deploy:
    jobs:
      - eks/annotation:
          app-name: Application name
          namespace: Namespace
          resource-name: deployment # deployment, statefulset or daemonset
          set-name: "kubernetes.io/previous-tag"
          get-current-name: kubernetes\.io\/current-tag
          set-path-annotation: .spec.template.metadata.annotations. # .metadata.annotations. -> StatefulSet
          get-current-value: true # get value from kubernetes.io/current-tag

      - eks/annotation:
          app-name: Application name
          namespace: Namespace
          resource-name: deployment # deployment, statefulset or daemonset
          set-name: "kubernetes.io/current-tag"
          set-value: "my value"
```
- Rollback

```yaml
version: 2.1
orbs:
  eks: tiendanube/eks@1.3.0
workflows:
  deploy:
    jobs:
      - eks/rollback:
        name: Job Name
        checkout: false
        app-name: Application name
        cluster-name: core
        region: Region
        namespace: Namespace
        resource-name: deployment # deployment, statefulset or daemonset
        restricted: true
        get-current-annotation-name: kubernetes\.io\/current-tag
        get-current-annotation-value: ${CIRCLE_SHA1:0:7}
        get-previous-annotation-name: kubernetes\.io\/previous-tag
        set-path-annotation: .spec.template.metadata.annotations. # .metadata.annotations. -> StatefulSet
        rollout-status: true
        rollout-status-watch: true
        rollout-status-timeout: 5m
        revert-commit: false
        branch-name: ${CIRCLE_BRANCH}
        github-sha1: ${CIRCLE_SHA1:0:7}
        github-token: ${GITHUB_TOKEN}
        github-repo: github.com/company/branch.git
        github-user-name: ${CIRCLE_USERNAME}
        github-user-email: email@company.com
```

- Revert commit

```yaml
version: 2.1
orbs:
  eks: tiendanube/eks@1.3.0
workflows:
  deploy:
    jobs:
    - eks/revert-commit:
        name: Job name
        checkout: false
        branch-name: ${CIRCLE_BRANCH}
        github-sha1: ${CIRCLE_SHA1:0:7}
        github-token: ${GITHUB_TOKEN}
        github-repo: github.com/company/branch.git
        github-user-name: ${CIRCLE_USERNAME}
        github-user-email: email@company.com
```

- AWS with Authenticator to Kubernetes

```yaml
version: 2.1

orbs:
  eks: tiendanube/eks@1.3.0

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
  eks: tiendanube/eks@1.3.0

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
  eks: tiendanube/eks@1.3.0

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
  eks: tiendanube/eks@1.3.0

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
  eks: tiendanube/eks@1.3.0

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