/**
 * Routes Onboarding__c trigger events to service classes.
 *
 * Field defaults, stage dates and stage history are handled by record-triggered flows.
 * Apex covers what flows can't do well:
 *  - CSM assignment, which shares running workload counts across every record in the batch
 *  - business-day durations, which need BusinessHours.diff to skip company holidays
 */
public with sharing class OnboardingTriggerHandler {
    @TestVisible
    private static final String BYPASS_PERMISSION = 'Bypass_Onboarding_Automation';

    public void run() {
        // Business days are derived from the stage dates, like the before-save flow's fields,
        // so they are kept up to date even when automation is bypassed for a data load.
        if (Trigger.isBefore && (Trigger.isInsert || Trigger.isUpdate)) {
            OnboardingBusinessDaysService.setBusinessDays((List<Onboarding__c>) Trigger.new);
        }

        if (FeatureManagement.checkPermission(BYPASS_PERMISSION)) {
            return;
        }

        switch on Trigger.operationType {
            when BEFORE_INSERT {
                OnboardingAssignmentService.assignOwners((List<Onboarding__c>) Trigger.new);
            }
            when AFTER_INSERT {
                OnboardingAssignmentService.notifyManagersOfBacklog((List<Onboarding__c>) Trigger.new);
            }
        }
    }
}
