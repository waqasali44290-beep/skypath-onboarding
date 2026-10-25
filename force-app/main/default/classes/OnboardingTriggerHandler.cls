/**
 * Routes Onboarding__c trigger events to service classes.
 *
 * Field defaults, stage dates and stage history are handled by record-triggered flows.
 * Only CSM assignment lives here, because it needs to share running workload counts
 * across every record in the batch, which a flow interview can't do.
 */
public with sharing class OnboardingTriggerHandler {
    @TestVisible
    private static final String BYPASS_PERMISSION = 'Bypass_Onboarding_Automation';

    public void run() {
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
