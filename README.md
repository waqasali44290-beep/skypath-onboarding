# SkyPath AI - Onboarding Tracker

Salesforce build for the SkyPath AI customer onboarding exercise. When a deal is won it gets an onboarding, the onboarding is handed to the CSM with the most room, and CS leadership can see where every customer is and how long each stage took.

Everything here is SFDX source and deploys with `sf project deploy start`. The design write-up (data model, trade-offs, assumptions, limitations) is submitted separately; this README is about getting it running.

## How it fits together

I used Flow and validation rules wherever they could do the job, and Apex only for the one piece they can't do well.

| Requirement | Where it lives |
| --- | --- |
| Won deal gets one onboarding | Record-triggered flow `Opportunity - After Save - Create Onboarding`. Only fires when a deal *becomes* won, and checks for an existing onboarding first. `Opportunity_Key__c` is a unique field, so the database rejects a duplicate even if something else tries to create one. |
| Never orphaned | `Opportunity__c` is a required lookup, the deal can't be deleted while the onboarding exists, and a validation rule stops it being re-pointed to another deal. |
| Readable name | Before-save flow sets the name to `Customer - Go-Live YYYY-MM-DD` on every save, so it stays right if the launch date moves. |
| Stage rules | Validation rules: forward one stage at a time, notes required to leave Gathering Info and Implementation, and the only backward move is QA / Review back to Implementation. |
| Stage dates | Before-save flow stamps `<Stage>_Reached_On__c` the first time each stage is reached and never overwrites it. A validation rule blocks manual edits. Formula fields give days between stages, so it all works in standard reports. |
| Stage history | After-save flow writes an `Onboarding_Stage_History__c` row for every move, including QA rework, with time spent in the previous stage. |
| CSM assignment | Apex (`OnboardingAssignmentService`), called from a single trigger on `Onboarding__c`. See below. |
| Record page | Lightning page "Revinfinity \| Onboarding Tracker" with Path, a Today tab, and a Stage History tab. |

### Why assignment is Apex

A record-triggered flow runs once per record, and those runs can't share state. With 200 deals closed in one Data Loader batch, every flow run would see the same workload numbers and pile onboardings onto whoever looked least busy at the start. Doing it in a before-insert trigger means workload is loaded once, updated in memory as each record is assigned, and the owner is set before the record is saved (no second update).

How it decides:

1. Eligible CSMs are active users with **CSM** ticked and **Max Active Onboardings** above 0. Both are fields on the user record, so admins manage the team without a deployment.
2. Current workload is one aggregate query: active onboardings (anything before Post-Launch Review) grouped by owner.
3. Each new onboarding goes to the eligible CSM with the lowest count who is still under their max. Ties go by name, so a batch is dealt out round-robin.
4. If nobody has room it goes to the **Onboarding Backlog** queue, and the **CS Managers** group gets one notification for the batch (not one per record).
5. The CSMs' active onboarding rows are read with `FOR UPDATE`, so a second batch running at the same time waits for this one to commit instead of giving away the same last slot. (Salesforce doesn't allow locking User rows, which is why the lock is on the onboardings.)

Queue, group and notification type are looked up by developer name from the `Onboarding_Setting__mdt` "Default" record. There are no hardcoded Ids anywhere.

### Leaving room for other teams

- One trigger per object, with no logic in the trigger itself. New logic goes into the handler.
- Flows are split by purpose (before-save field updates, after-save related records) so other teams can add their own without editing these.
- A `Bypass_Onboarding_Automation` custom permission (via the *Onboarding - Automation Bypass* permission set) switches off the validation rules, onboarding creation and assignment for data migrations.

## Setup

### Prerequisites

- Salesforce CLI: `npm install @salesforce/cli --global`
- A Developer Edition org (or a scratch org; `config/project-scratch-def.json` is included)

### Deploy

```bash
git clone <this repo>
cd skypath-onboarding

sf org login web --alias skypath --set-default
sf project deploy start
```

### After deploying

Give yourself the admin permission set, then run the setup script. The permission set has to come first: anonymous Apex only sees fields you have access to, and the CSM fields on User are granted by that permission set.

```bash
sf org assign permset --name Onboarding_Admin
sf apex run --file scripts/apex/1-setup-demo-users.apex
```

The script creates two demo CSMs (Jordan Reyes, capacity 4, and Sam Patel, capacity 10) on Salesforce Platform licences, gives them the CSM permission set and adds you to the CS Managers group.

A Developer Edition org only has a few spare user licences, so the demo uses two CSMs. Adding more in a real org is the same as what the script does: open the user, tick **CSM**, set **Max Active Onboardings**, assign **Onboarding - CSM**.

If you'd rather do it by hand:

1. Assign **Onboarding - Admin** to yourself.
2. For each CSM: tick **CSM** on their user record, set **Max Active Onboardings**, assign **Onboarding - CSM**.
3. Add CS managers to the **CS Managers** public group (Setup > Public Groups). They get backlog alerts and can work the Onboarding Backlog queue. Give them **Onboarding - CS Manager**.

Then open the **Onboarding Tracker** app from the App Launcher.

### Trying it out

```bash
# 10 customers, 200 open deals
sf apex run --file scripts/apex/2-create-demo-deals.apex

# quarter-end: close all 200 as won in one update, prints the spread per owner
sf apex run --file scripts/apex/3-bulk-close-demo-deals.apex

# clean up
sf apex run --file scripts/apex/4-reset-demo-data.apex
```

With the two demo CSMs, the bulk close gives Jordan 4 and Sam 10, and the other 186 go to the backlog. To see an even split before anyone fills up, set `dealsToClose = 6` at the top of script 3.

You can do the same thing with Data Loader: export the open demo deals and update `StageName` to `Closed Won`. It goes through the same automation.

## Tests

```bash
sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 10
```

- `OnboardingAssignmentServiceTest`: least-loaded assignment, tie-breaking, completed onboardings freeing capacity, ineligible users being skipped, backlog overflow with a single alert, and two 200-record tests (closing 200 deals in one update): one checks the even 67/67/66 split, one checks per-CSM caps of 4/10/6 with the other 180 in the backlog.
- `OnboardingLifecycleTest`: tests the flows and validation rules through real DML. It covers creation and naming, no duplicate on re-close, the unique key, delete protection, stage skipping, required notes, QA rework keeping the original dates, and locked dates.

The tests switch off any real CSMs in the org while they run, so your org's own config doesn't change the results.

## Naming conventions

| Thing | Convention | Example |
| --- | --- | --- |
| Objects and fields | Words separated by underscores, no abbreviations | `Onboarding__c`, `Target_Go_Live_Date__c` |
| Stage date fields | `<Stage>_Reached_On__c` | `QA_Review_Reached_On__c` |
| Duration fields | `Days_<From>_To_<To>__c` | `Days_Implementation_To_QA__c` |
| Booleans | `Is_` prefix | `Is_Active__c`, `Is_CSM__c` |
| Picklist values | API name in snake case, label as the business says it | `QA_Review` / "QA / Review" |
| Flows | `<Object>_<When>_<What it does>` | `Onboarding_Before_Save_Set_Fields` |
| Validation rules | What they enforce | `Prevent_Stage_Skip`, `Lock_Stage_Reached_Dates` |
| Apex | `<Object>Trigger`, `<Object>TriggerHandler`, `<Purpose>Service`, `<Class>Test` | `OnboardingAssignmentService` |
| Permission sets | `Onboarding_<Persona>` | `Onboarding_CSM`, `Onboarding_Manager` |

## Project layout

```
force-app/main/default/
  applications/        Onboarding Tracker app
  classes/             assignment service, trigger handler, tests
  customMetadata/      Onboarding_Setting.Default
  flexipages/          Revinfinity | Onboarding Tracker record page
  flows/               the three record-triggered flows
  globalValueSets/     Onboarding_Stage (shared by Stage and stage history)
  objects/             Onboarding__c, Onboarding_Stage_History__c, Onboarding_Setting__mdt, User fields
  pathAssistants/      stage guidance shown on the Path
  permissionsets/      CSM, CS Manager, Admin, Automation Bypass
  queues/ groups/      Onboarding Backlog queue, CS Managers group
  triggers/            OnboardingTrigger
scripts/apex/          demo setup, bulk close and reset
```

## Known gaps

- Durations are calendar days. Business days (weekends and company holidays excluded) would use Business Hours and Holidays in Setup plus `BusinessHours.diff()` when each stage is stamped. This is covered in the write-up, not built.
- Onboardings in the backlog aren't picked up automatically when a CSM frees up; a manager assigns them. A scheduled flow that drains the backlog is the obvious next step.
- The concurrency lock only has rows to hold once CSMs have active onboardings. For the quarter-end load I'd still run Data Loader in serial mode, which also avoids lock waits.
- Assignment counts onboardings, not effort. A large enterprise onboarding counts the same as a small one.
