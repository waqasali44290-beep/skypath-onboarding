trigger OnboardingTrigger on Onboarding__c(
    before insert,
    before update,
    before delete,
    after insert,
    after update,
    after delete,
    after undelete
) {
    // All events are subscribed so new logic only needs a branch in the handler, never a second trigger.
    new OnboardingTriggerHandler().run();
}
