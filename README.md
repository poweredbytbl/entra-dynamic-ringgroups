# Entra ID user deployment rings

This implementation makes **Ring 2** an assigned security group whose membership is reconciled by an Azure Automation PowerShell runbook. Rings **0**, **1**, and **3** stay assigned security groups and are edited directly by administrators.

## Recommended design

```text
User attributes ──> Eligibility dynamic group ──┐
                                                  ├─> scheduled reconciliation ──> Ring 2 (assigned group)
Ring 0 (assigned) ──────────────────────────────┤
Ring 1 (assigned) ──────────────────────────────┤  excluded
Ring 3 (assigned) ──────────────────────────────┘
```

Create a fifth, internal security group named something like `SG-Deployment-Ring-Eligible`. Make it a **Dynamic User** group and put the business condition in its normal Entra dynamic-membership rule. This is the population eligible to participate in the ring program; it is not specific to Ring 2. For example, to target active internal users whose department is Engineering:

```text
(user.accountEnabled -eq true) -and
(user.userType -eq "Member") -and
(user.department -eq "Engineering")
```

The supplied runbook treats that group as the source of truth for eligibility and calculates:

```text
Ring 2 = Eligible − (Ring 0 ∪ Ring 1 ∪ Ring 3)
```

It adds every missing desired user and removes every Ring 2 user who is no longer eligible or has entered an exclusion ring. It never changes Rings 0, 1, or 3.

### Naming is configurable

All group names in this guide are examples. The implementation never looks up or evaluates a group by display name: it receives the immutable object IDs of the five groups as runbook parameters. You can therefore use any local naming convention for the eligibility group and the four ring groups. The parameter names describe each group's **role** in the calculation, not its required display name.

Do **not** make Ring 2 dynamic and do not use the `memberOf` dynamic-rule preview for this. Microsoft documents that `memberOf` cannot be combined with another rule or used for exclusions, and advises avoiding it in production because it remains preview functionality. The eligibility group itself uses stable, attribute-based dynamic membership; the short runbook supplies the missing group-exclusion logic. See [dynamic membership rules](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-membership) and [the `memberOf` preview limitations](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-rule-member-of).

## One-time setup

1. Create four **assigned Security** groups: `Ring 0 Users`, `Ring 1 Users`, `Ring 2 Users`, and `Ring 3 Users`. Do not use a role-assignable group for Ring 2.
2. Create the `Ring-Eligible` dynamic-user security group and define the eligibility rule. Make attribute ownership clear: anyone able to edit attributes used by this rule can alter ring-program targeting.
3. Create an Azure Automation Account using a PowerShell 7.2 runbook, enable its **system-assigned managed identity**, and import the `Microsoft.Graph.Authentication` module (v2.x).
4. Grant the managed identity the Microsoft Graph **application** permission `GroupMember.ReadWrite.All` and grant tenant-wide admin consent. This is the least-privileged Graph application permission for adding and removing user group members; the runbook only reads member IDs and changes Ring 2. Do not grant `Directory.ReadWrite.All`.
5. Publish [Sync-Ring2Membership.ps1](./src/Sync-Ring2Membership.ps1) as the runbook. Configure the five group-object-ID parameters on the schedule, starting with `-WhatIf` for the first run.
6. Schedule it hourly. If a slower response is acceptable, every four hours is also reasonable. Dynamic-group evaluation is asynchronous, so this interval is a maximum additional delay after eligibility is evaluated.
7. Add an Azure Monitor alert for failed runbook jobs. Review the normal runbook output after the first few runs.

The safe `/$ref` removal endpoint in the script removes a **membership reference**, not the user object. Microsoft Graph specifically cautions that omitting `/$ref` can delete the directory object when permissions allow it. See [remove group member](https://learn.microsoft.com/en-us/graph/api/group-delete-members?view=graph-rest-1.0).

### Granting the Graph permission

Run the following once as an appropriately privileged administrator, after enabling the Automation Account identity. It uses the `Az.Resources` module; replace the Automation Account name before running.

```powershell
$automationAccountName = '<Automation account name>'

$mi = Get-AzADServicePrincipal -DisplayName $automationAccountName
$graph = Get-AzADServicePrincipal -Filter "displayName eq 'Microsoft Graph'"
$role = $graph.AppRole | Where-Object {
    $_.Value -eq 'GroupMember.ReadWrite.All' -and $_.AllowedMemberTypes -contains 'Application'
}

New-AzADServicePrincipalAppRoleAssignment `
    -ObjectId $mi.Id `
    -PrincipalId $mi.Id `
    -ResourceId $graph.Id `
    -AppRoleId $role.Id
```

The account name is normally the managed identity service-principal display name. Verify the service-principal IDs before executing the assignment.

## Runbook schedule parameters

Use immutable object IDs, not group display names:

```powershell
-EligibilityGroupId '11111111-1111-1111-1111-111111111111' `
-Ring0GroupId       '22222222-2222-2222-2222-222222222222' `
-Ring1GroupId       '33333333-3333-3333-3333-333333333333' `
-Ring2GroupId       '44444444-4444-4444-4444-444444444444' `
-Ring3GroupId       '55555555-5555-5555-5555-555555555555'
```

For the first execution, append `-WhatIf`. It produces the counts and IDs that would be changed without modifying Ring 2. Remove `-WhatIf` only after reviewing that output.

## Cost and operations

This design has no server, secret, certificate rotation, or third-party service. Azure Automation bills by job runtime; its Basic SKU includes the first 500 job-runtime minutes per subscription per month. A small hourly reconciliation normally fits easily within that allowance, but the allowance is shared with other Automation jobs in the subscription. Confirm your subscription's billing and run duration before relying on the free allocation. [Azure Automation billing and limits](https://learn.microsoft.com/en-us/azure/automation/automation-subscription-limits-faq)

Routine support is limited to reviewing a failed-job alert. Changes to the eligibility rule occur in Entra on the `Ring-Eligible` group and require no runbook code changes.

## Important operating boundaries

- Ring 2 is exclusively automation-managed. Administrators should change membership through the eligibility rule or an exclusion ring, never by manually editing Ring 2.
- This implementation compares **direct** group memberships. Do not nest groups inside Rings 0–3. If nested groups are an unavoidable requirement, the definition of "member" must be changed to transitive membership and the runbook should be adjusted and load-tested.
- A user in any exclusion group is removed from Ring 2 on the next successful schedule, regardless of eligibility.
- Keep Ring 0, 1, 2, and 3 user-only security groups. Service principals, devices, contacts, and nested groups are ignored.
- Protect the dynamic-rule attributes and group ownership through normal Entra RBAC/PIM practices.

## Validation checklist

1. Add a test user that matches the eligibility rule; wait for the eligibility group to evaluate; run the job and confirm they join Ring 2.
2. Add the same user to each of Ring 0, Ring 1, and Ring 3 in turn; run the job and confirm they are removed from Ring 2.
3. Make the user ineligible; after dynamic processing and the next run, confirm they are removed from Ring 2.
4. Put an ineligible user directly into Ring 2; confirm the next job removes them.
5. Confirm the job's managed identity has only `GroupMember.ReadWrite.All` among Microsoft Graph application permissions.
