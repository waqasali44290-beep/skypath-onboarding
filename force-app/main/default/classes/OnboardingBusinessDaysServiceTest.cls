/**
 * Relies on the "SkyPath Business Days" Business Hours (Mon-Fri, full days) and its holidays,
 * which are deployed with the project. Every span below is a whole week starting at midday, so
 * the expected counts hold whatever timezone the test user or the Business Hours are in.
 */
@IsTest
private class OnboardingBusinessDaysServiceTest {
    @IsTest
    static void usesConfiguredSkyPathBusinessHours() {
        Id expected = [SELECT Id FROM BusinessHours WHERE Name = 'SkyPath Business Days'].Id;
        Assert.areEqual(expected, OnboardingBusinessDaysService.getBusinessHoursId());
    }

    @IsTest
    static void weekendsAreNotCounted() {
        Datetime wednesday = Datetime.newInstance(2026, 11, 4, 12, 0, 0);

        Decimal businessDays = OnboardingBusinessDaysService.businessDaysBetween(
            OnboardingBusinessDaysService.getBusinessHoursId(),
            wednesday,
            wednesday.addDays(7)
        );

        Assert.areEqual(5.0, businessDays, '7 calendar days containing one weekend = 5 business days');
    }

    @IsTest
    static void companyHolidaysAreNotCounted() {
        Datetime mondayBeforeChristmas = Datetime.newInstance(2026, 12, 21, 12, 0, 0);

        Decimal businessDays = OnboardingBusinessDaysService.businessDaysBetween(
            OnboardingBusinessDaysService.getBusinessHoursId(),
            mondayBeforeChristmas,
            mondayBeforeChristmas.addDays(7)
        );

        Assert.areEqual(4.0, businessDays, 'Christmas Day 2026 falls on a Friday, so the week has 4 business days');
    }

    @IsTest
    static void fillsOnlyDurationsWhoseStagesHaveBeenReached() {
        Datetime kickoff = Datetime.newInstance(2026, 11, 4, 12, 0, 0);
        Onboarding__c onboarding = new Onboarding__c(
            Kickoff_Scheduled_Reached_On__c = kickoff,
            Gathering_Info_Reached_On__c = kickoff.addDays(7)
        );

        OnboardingBusinessDaysService.setBusinessDays(new List<Onboarding__c>{ onboarding });

        Assert.areEqual(5.0, onboarding.Business_Days_Kickoff_To_Gathering_Info__c);
        Assert.isNull(onboarding.Business_Days_Info_To_Implementation__c, 'Implementation not reached yet');
        Assert.isNull(onboarding.Business_Days_Kickoff_To_Go_Live__c, 'Go Live not reached yet');
    }

    @IsTest
    static void calculatedWhenOnboardingMovesThroughStages() {
        OnboardingTestDataFactory.createCsms(new Map<String, Integer>{ 'Avery' => 10 });
        Account account = OnboardingTestDataFactory.createAccount('Contoso');
        Onboarding__c onboarding = OnboardingTestDataFactory.createOnboardings(
            OnboardingTestDataFactory.createOpenOpportunities(account.Id, 1)
        )[0];

        Test.startTest();
        OnboardingTestDataFactory.advanceTo(onboarding.Id, 'Implementation');
        Test.stopTest();

        Onboarding__c saved = [
            SELECT Business_Days_Kickoff_To_Gathering_Info__c, Business_Days_Info_To_Implementation__c, Business_Days_Implementation_To_QA__c
            FROM Onboarding__c
            WHERE Id = :onboarding.Id
        ];
        Assert.isNotNull(saved.Business_Days_Kickoff_To_Gathering_Info__c, 'Trigger fills durations once both stages are reached');
        Assert.isNotNull(saved.Business_Days_Info_To_Implementation__c);
        Assert.isNull(saved.Business_Days_Implementation_To_QA__c, 'QA not reached yet');
    }
}
