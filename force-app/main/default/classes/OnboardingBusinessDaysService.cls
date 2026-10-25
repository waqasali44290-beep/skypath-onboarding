/**
 * Fills in the Business_Days_* duration fields: time between first reaching two stages,
 * counting working days only (weekends and company holidays excluded).
 *
 * Uses the Business Hours record named in Onboarding_Setting__mdt (full days Monday to Friday,
 * with holidays attached in Setup > Holidays), falling back to the org default Business Hours.
 * This is Apex because formula fields and flows can't see holidays; BusinessHours.diff can.
 *
 * Runs before insert/update, after the before-save flow has stamped the stage dates. The stamped
 * dates never change, so recalculating on every save is safe and costs no extra queries.
 */
public with sharing class OnboardingBusinessDaysService {
    private static final Decimal MILLISECONDS_PER_DAY = 24 * 60 * 60 * 1000;

    private static final List<Duration> DURATIONS = new List<Duration>{
        new Duration(
            Onboarding__c.Kickoff_Scheduled_Reached_On__c,
            Onboarding__c.Gathering_Info_Reached_On__c,
            Onboarding__c.Business_Days_Kickoff_To_Gathering_Info__c
        ),
        new Duration(
            Onboarding__c.Gathering_Info_Reached_On__c,
            Onboarding__c.Implementation_Reached_On__c,
            Onboarding__c.Business_Days_Info_To_Implementation__c
        ),
        new Duration(
            Onboarding__c.Implementation_Reached_On__c,
            Onboarding__c.QA_Review_Reached_On__c,
            Onboarding__c.Business_Days_Implementation_To_QA__c
        ),
        new Duration(Onboarding__c.QA_Review_Reached_On__c, Onboarding__c.Go_Live_Reached_On__c, Onboarding__c.Business_Days_QA_To_Go_Live__c),
        new Duration(
            Onboarding__c.Go_Live_Reached_On__c,
            Onboarding__c.Post_Launch_Review_Reached_On__c,
            Onboarding__c.Business_Days_Go_Live_To_Post_Launch__c
        ),
        new Duration(
            Onboarding__c.Kickoff_Scheduled_Reached_On__c,
            Onboarding__c.Go_Live_Reached_On__c,
            Onboarding__c.Business_Days_Kickoff_To_Go_Live__c
        )
    };

    private static Id cachedBusinessHoursId;

    public static void setBusinessDays(List<Onboarding__c> onboardings) {
        Id businessHoursId = getBusinessHoursId();
        for (Onboarding__c onboarding : onboardings) {
            for (Duration duration : DURATIONS) {
                Datetime reachedFrom = (Datetime) onboarding.get(duration.fromField);
                Datetime reachedTo = (Datetime) onboarding.get(duration.toField);
                onboarding.put(
                    duration.resultField,
                    reachedFrom == null || reachedTo == null ? null : businessDaysBetween(businessHoursId, reachedFrom, reachedTo)
                );
            }
        }
    }

    @TestVisible
    private static Decimal businessDaysBetween(Id businessHoursId, Datetime reachedFrom, Datetime reachedTo) {
        Long milliseconds = BusinessHours.diff(businessHoursId, reachedFrom, reachedTo);
        return (milliseconds / MILLISECONDS_PER_DAY).setScale(1, RoundingMode.HALF_UP);
    }

    @TestVisible
    private static Id getBusinessHoursId() {
        if (cachedBusinessHoursId == null) {
            Onboarding_Setting__mdt settings = Onboarding_Setting__mdt.getInstance('Default');
            String name = settings?.Business_Hours_Name__c;
            List<BusinessHours> configured = [SELECT Id FROM BusinessHours WHERE Name = :name AND IsActive = TRUE LIMIT 1];
            cachedBusinessHoursId = configured.isEmpty() ? [SELECT Id FROM BusinessHours WHERE IsDefault = TRUE LIMIT 1].Id : configured[0].Id;
        }
        return cachedBusinessHoursId;
    }

    private class Duration {
        final SObjectField fromField;
        final SObjectField toField;
        final SObjectField resultField;

        Duration(SObjectField fromField, SObjectField toField, SObjectField resultField) {
            this.fromField = fromField;
            this.toField = toField;
            this.resultField = resultField;
        }
    }
}
