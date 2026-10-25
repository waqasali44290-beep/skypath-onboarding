/**
 * Covers the declarative side of the build (flows and validation rules) through real DML,
 * so a broken flow or rule fails a test instead of a demo.
 */
@IsTest
private class OnboardingLifecycleTest {
    @TestSetup
    static void setup() {
        OnboardingTestDataFactory.createCsms(new Map<String, Integer>{ 'Avery' => 50 });
        Account account = OnboardingTestDataFactory.createAccount('Northwind Traders');
        OnboardingTestDataFactory.createOpenOpportunities(account.Id, 1);
    }

    @IsTest
    static void winningDealCreatesOneNamedOnboarding() {
        Opportunity deal = getDeal();

        Test.startTest();
        OnboardingTestDataFactory.closeAsWon(new List<Opportunity>{ deal });
        Test.stopTest();

        Onboarding__c onboarding = getOnboarding(deal.Id);
        Integer daysToGoLive = Onboarding_Setting__mdt.getInstance('Default').Days_To_Go_Live__c.intValue();
        // Re-read the deal: Salesforce moves Close Date to today when a deal is closed early.
        Date expectedGoLive = getDeal().CloseDate.addDays(daysToGoLive);

        Assert.areEqual(expectedGoLive, onboarding.Target_Go_Live_Date__c);
        Assert.areEqual('Northwind Traders - Go-Live ' + String.valueOf(expectedGoLive), onboarding.Name, 'Name shows customer and launch date');
        Assert.areEqual('Kickoff_Scheduled', onboarding.Stage__c);
        Assert.areEqual(deal.Id, onboarding.Opportunity_Key__c);
        Assert.isNotNull(onboarding.Kickoff_Scheduled_Reached_On__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Onboarding_Stage_History__c WHERE Onboarding__c = :onboarding.Id]);
    }

    @IsTest
    static void reopeningAndClosingAgainDoesNotCreateSecondOnboarding() {
        Opportunity deal = getDeal();
        OnboardingTestDataFactory.closeAsWon(new List<Opportunity>{ deal });

        Test.startTest();
        update new Opportunity(Id = deal.Id, StageName = OnboardingTestDataFactory.getOpenStageName());
        OnboardingTestDataFactory.closeAsWon(new List<Opportunity>{ deal });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Onboarding__c WHERE Opportunity__c = :deal.Id]);
    }

    @IsTest
    static void databaseRejectsSecondOnboardingForSameDeal() {
        Opportunity deal = getDeal();
        OnboardingTestDataFactory.closeAsWon(new List<Opportunity>{ deal });

        DmlException error;
        Test.startTest();
        try {
            OnboardingTestDataFactory.createOnboardings(new List<Opportunity>{ deal });
        } catch (DmlException e) {
            error = e;
        }
        Test.stopTest();

        Assert.isNotNull(error, 'A second onboarding for the same deal should be rejected');
        Assert.areEqual(StatusCode.DUPLICATE_VALUE, error.getDmlType(0));
    }

    @IsTest
    static void wonDealCannotBeDeletedWhileOnboardingExists() {
        Opportunity deal = getDeal();
        OnboardingTestDataFactory.closeAsWon(new List<Opportunity>{ deal });

        DmlException error;
        Test.startTest();
        try {
            delete deal;
        } catch (DmlException e) {
            error = e;
        }
        Test.stopTest();

        Assert.isNotNull(error, 'Deleting the deal would orphan the onboarding');
        Assert.areEqual(StatusCode.DELETE_FAILED, error.getDmlType(0));
    }

    @IsTest
    static void dealOnOnboardingCannotBeChanged() {
        Onboarding__c onboarding = createOnboarding();
        Opportunity otherDeal = OnboardingTestDataFactory.createOpenOpportunities(getDeal().AccountId, 1)[0];

        DmlException error;
        Test.startTest();
        try {
            update new Onboarding__c(Id = onboarding.Id, Opportunity__c = otherDeal.Id);
        } catch (DmlException e) {
            error = e;
        }
        Test.stopTest();

        assertRejectedWith(error, 'deal on an onboarding');
    }

    @IsTest
    static void stagesCannotBeSkipped() {
        Onboarding__c onboarding = createOnboarding();

        DmlException error;
        Test.startTest();
        try {
            update new Onboarding__c(Id = onboarding.Id, Stage__c = 'Implementation', Gathering_Info_Notes__c = 'Notes');
        } catch (DmlException e) {
            error = e;
        }
        Test.stopTest();

        assertRejectedWith(error, 'skipped');
    }

    @IsTest
    static void gatheringInfoNotesAreRequiredToMoveOn() {
        Onboarding__c onboarding = createOnboarding();
        update new Onboarding__c(Id = onboarding.Id, Stage__c = 'Gathering_Info');

        DmlException error;
        Test.startTest();
        try {
            update new Onboarding__c(Id = onboarding.Id, Stage__c = 'Implementation');
        } catch (DmlException e) {
            error = e;
        }
        update new Onboarding__c(Id = onboarding.Id, Stage__c = 'Implementation', Gathering_Info_Notes__c = 'Customer uses Okta SSO.');
        Test.stopTest();

        assertRejectedWith(error, 'Gathering Info notes');
        Assert.areEqual('Implementation', getOnboarding(getDeal().Id).Stage__c, 'Moves on once notes are captured');
    }

    @IsTest
    static void implementationNotesAreRequiredToMoveOn() {
        Onboarding__c onboarding = createOnboarding();
        OnboardingTestDataFactory.advanceTo(onboarding.Id, 'Implementation');
        update new Onboarding__c(Id = onboarding.Id, Implementation_Notes__c = null);

        DmlException error;
        Test.startTest();
        try {
            update new Onboarding__c(Id = onboarding.Id, Stage__c = 'QA_Review');
        } catch (DmlException e) {
            error = e;
        }
        Test.stopTest();

        assertRejectedWith(error, 'Implementation notes');
    }

    @IsTest
    static void failedQaGoesBackToImplementationWithoutRewritingHistory() {
        Onboarding__c onboarding = createOnboarding();
        OnboardingTestDataFactory.advanceTo(onboarding.Id, 'QA_Review');
        Onboarding__c beforeRework = getOnboarding(getDeal().Id);

        Test.startTest();
        update new Onboarding__c(Id = onboarding.Id, Stage__c = 'Implementation');
        update new Onboarding__c(Id = onboarding.Id, Stage__c = 'QA_Review');
        Test.stopTest();

        Onboarding__c afterRework = getOnboarding(getDeal().Id);
        Assert.areEqual('QA_Review', afterRework.Stage__c);
        Assert.areEqual(1, afterRework.QA_Rework_Count__c);
        Assert.areEqual(beforeRework.Implementation_Reached_On__c, afterRework.Implementation_Reached_On__c, 'First-reached dates never move');
        Assert.areEqual(beforeRework.QA_Review_Reached_On__c, afterRework.QA_Review_Reached_On__c, 'First-reached dates never move');

        List<Onboarding_Stage_History__c> reworkEntries = [
            SELECT From_Stage__c, To_Stage__c
            FROM Onboarding_Stage_History__c
            WHERE Onboarding__c = :onboarding.Id AND Is_Rework__c = TRUE
        ];
        Assert.areEqual(1, reworkEntries.size());
        Assert.areEqual('QA_Review', reworkEntries[0].From_Stage__c);
        Assert.areEqual('Implementation', reworkEntries[0].To_Stage__c);
        // created + 3 forward moves + back to Implementation + forward to QA again
        Assert.areEqual(6, [SELECT COUNT() FROM Onboarding_Stage_History__c WHERE Onboarding__c = :onboarding.Id]);
    }

    @IsTest
    static void otherBackwardMovesAreBlocked() {
        Onboarding__c onboarding = createOnboarding();
        OnboardingTestDataFactory.advanceTo(onboarding.Id, 'Implementation');

        DmlException error;
        Test.startTest();
        try {
            update new Onboarding__c(Id = onboarding.Id, Stage__c = 'Gathering_Info');
        } catch (DmlException e) {
            error = e;
        }
        Test.stopTest();

        assertRejectedWith(error, 'only move back from QA');
    }

    @IsTest
    static void stageReachedDatesCannotBeEdited() {
        Onboarding__c onboarding = createOnboarding();

        DmlException error;
        Test.startTest();
        try {
            update new Onboarding__c(Id = onboarding.Id, Kickoff_Scheduled_Reached_On__c = Datetime.now().addDays(-10));
        } catch (DmlException e) {
            error = e;
        }
        Test.stopTest();

        assertRejectedWith(error, 'history');
    }

    @IsTest
    static void newOnboardingsMustStartAtKickoff() {
        Opportunity deal = getDeal();

        DmlException error;
        Test.startTest();
        try {
            insert new Onboarding__c(
                Name = 'Manual',
                Opportunity__c = deal.Id,
                Stage__c = 'Implementation',
                Target_Go_Live_Date__c = Date.today(),
                Gathering_Info_Notes__c = 'Notes'
            );
        } catch (DmlException e) {
            error = e;
        }
        Test.stopTest();

        assertRejectedWith(error, 'start at Kickoff');
    }

    // ---------- helpers ----------

    private static void assertRejectedWith(DmlException error, String expectedMessagePart) {
        Assert.isNotNull(error, 'Expected the save to be rejected');
        Assert.isTrue(error.getMessage().contains(expectedMessagePart), 'Unexpected error: ' + error.getMessage());
    }

    private static Onboarding__c createOnboarding() {
        Opportunity deal = getDeal();
        OnboardingTestDataFactory.closeAsWon(new List<Opportunity>{ deal });
        return getOnboarding(deal.Id);
    }

    private static Opportunity getDeal() {
        return [SELECT Id, Name, AccountId, CloseDate FROM Opportunity WHERE Account.Name = 'Northwind Traders' ORDER BY CreatedDate, Id LIMIT 1];
    }

    private static Onboarding__c getOnboarding(Id opportunityId) {
        return [
            SELECT
                Id,
                Name,
                Stage__c,
                Target_Go_Live_Date__c,
                Opportunity_Key__c,
                QA_Rework_Count__c,
                Kickoff_Scheduled_Reached_On__c,
                Implementation_Reached_On__c,
                QA_Review_Reached_On__c
            FROM Onboarding__c
            WHERE Opportunity__c = :opportunityId
        ];
    }
}
