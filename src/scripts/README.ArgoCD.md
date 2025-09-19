# ArgoCD Rollout Decision Logic

## 🚫 Rollout Blocked
These conditions prevent a rollout from continuing and require manual intervention:

- **⏸️ Canary Rollout in Progress**
  - `health.status`: `Suspended` (regardless of sync status)
  - _Reason_: A canary deployment is currently paused, waiting for manual approval or verification before proceeding to the next phase.

- **⏳ Reconciliation Blocked**
  - `operationState.phase`: `Running`
  - _Reason_: The application is stuck in a reconciliation loop, indicating potential resource conflicts or configuration issues that need to be resolved before continuing.

## ✅ Rollout Allowed
The following conditions allow a rollout to continue or complete. These scenarios are not explicitly handled by any code; they are identified cases where the ORB will not cancel the rollout process.

- **✅ Happy Path (Default Case):**  
  - All statuses are healthy and in sync (`health.status`: `Healthy`, `sync.status`: `Synced`, `operationState.phase`: `Succeeded`).  
  - _Reason_: Everything is operating as expected, so the rollout will proceed normally.

- **↩️ Rollback Operation**
  - `health.status`: `Healthy`, `sync.status`: `OutOfSync` (with _AutoSync_ **disabled** 🔒), and `operationState.phase`: `Succeeded`
  - _Reason_: The application is healthy but intentionally out of sync due to a rollback operation that has completed successfully.

- **🛑 Abort Operation**
  - `health.status`: `Degraded`, `sync.status`: `Synced` (with _AutoSync_ **enabled** 🔄), and `operationState.phase`: `Succeeded`
  - _Reason_: The application is in a degraded state but has successfully synced, indicating an abort operation that has completed and the system is ready for the next phase.

# ArgoCD Application JSON fields reference
## status.sync.status
The field `status.sync.status` in the _ArgoCD Application_ resource indicates the **synchronization** state between the desired configuration (as defined in _Git_) and the actual state of the resources in the cluster.
Possible values:
- `Synced`: The live state matches the desired state in Git.
- `OutOfSync`: The live state differs from the desired state in Git (there are changes to apply).
- `Unknown`: The sync status could not be determined (e.g., due to errors or missing information).

## status.health.status
The field `status.health.status` in the _ArgoCD Application_ resource describes the **health** of the application as determined by _ArgoCD_. This field helps you understand whether the application and its resources are operating as expected.

Possible values:
- `Healthy`: The application is operating normally and all resources are in the desired state.
- `Progressing`: The application is being updated or is in the process of reconciling changes.
- `Suspended`: The application rollout or sync is paused, often due to a manual intervention or a canary rollout step.
- `Degraded`: One or more resources are in a failed or error state.
- `Missing`: Some resources defined in the desired state are not found in the cluster.
- `Unknown`: The health status could not be determined, possibly due to errors or missing information.

## status.operationState.phase
The field `status.operationState.phase` in the _ArgoCD Application_ resource represents the **current phase of the most recent operation** (such as a sync or rollback) performed on the application.

Possible values:
- `Running`: An operation (e.g., sync or rollback) is currently in progress. In the ArgoCD UI, this is often shown as "Syncing".
- `Succeeded`: The last operation completed successfully. In the ArgoCD UI, this is often shown as "Sync OK".
- `Failed`: The last operation did not complete successfully due to an error or issue with the resources.
- `Error`: An unexpected error occurred during the operation.
