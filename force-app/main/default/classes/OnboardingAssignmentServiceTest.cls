@IsTest
private class OnboardingAssignmentServiceTest {
    @IsTest
    static void assignsToCsmWithFewestActiveOnboardings() {
        Map<String, User> csms = OnboardingTestDataFactory.createCsms(new Map<String, Integer>{ 'Avery' => 10, 'Blake' => 10 });
        Account account = OnboardingTestDataFactory.createAccount('Contoso');
        List<Opportunity> deals = OnboardingTestDataFactory.createOpenOpportunities(account.Id, 5);

        // Give Avery two existing onboardings so Blake is the least loaded.
        List<Onboarding__c> existing = OnboardingTestDataFactory.createOnboardings(new List<Opportunity>{ deals[0], deals[1] });
        for (Onboarding__c onboarding : existing) {
            onboarding.OwnerId = csms.get('Avery').Id;
        }
        update existing;

        Test.startTest();
        List<Onboarding__c> created = OnboardingTestDataFactory.createOnboardings(new List<Opportunity>{ deals[2], deals[3], deals[4] });
        Test.stopTest();

        Map<Id, Onboarding__c> byId = new Map<Id, Onboarding__c>([SELECT Id, OwnerId FROM Onboarding__c WHERE Id IN :created]);
        Assert.areEqual(csms.get('Blake').Id, byId.get(created[0].Id).OwnerId, 'Blake had 0 vs Avery 2, so Blake gets the first one');
        Assert.areEqual(csms.get('Blake').Id, byId.get(created[1].Id).OwnerId, 'Blake 1 vs Avery 2, so Blake again');
        Assert.areEqual(csms.get('Avery').Id, byId.get(created[2].Id).OwnerId, 'Tied at 2, tie goes to Avery (name order)');
    }

    @IsTest
    static void completedOnboardingsDoNotCountTowardsCapacity() {
        Map<String, User> csms = OnboardingTestDataFactory.createCsms(new Map<String, Integer>{ 'Avery' => 1 });
        Account account = OnboardingTestDataFactory.createAccount('Contoso');
        List<Opportunity> deals = OnboardingTestDataFactory.createOpenOpportunities(account.Id, 2);

        Onboarding__c finished = OnboardingTestDataFactory.createOnboardings(new List<Opportunity>{ deals[0] })[0];
        Assert.areEqual(csms.get('Avery').Id, [SELECT OwnerId FROM Onboarding__c WHERE Id = :finished.Id].OwnerId);
        OnboardingTestDataFactory.advanceTo(finished.Id, 'Post_Launch_Review');

        Test.startTest();
        Onboarding__c next = OnboardingTestDataFactory.createOnboardings(new List<Opportunity>{ deals[1] })[0];
        Test.stopTest();

        Assert.areEqual(
            csms.get('Avery').Id,
            [SELECT OwnerId FROM Onboarding__c WHERE Id = :next.Id].OwnerId,
            'An onboarding in Post-Launch Review is no longer active, so Avery has room again'
        );
    }

    @IsTest
    static void ignoresUsersWhoAreNotEligibleCsms() {
        Map<String, User> csms = OnboardingTestDataFactory.createCsms(new Map<String, Integer>{ 'Casey' => 5 });
        User nonCsm = OnboardingTestDataFactory.buildUser('Drew', false, 10);
        User inactiveCsm = OnboardingTestDataFactory.buildUser('Ellis', true, 10);
        inactiveCsm.IsActive = false;
        User zeroCapacityCsm = OnboardingTestDataFactory.buildUser('Finley', true, 0);
        User noCapacityCsm = OnboardingTestDataFactory.buildUser('Gray', true, null);
        List<User> ineligible = new List<User>{ nonCsm, inactiveCsm, zeroCapacityCsm, noCapacityCsm };
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert ineligible;
        }
        // Put the ineligible users in scope too, so the service itself has to filter them out.
        List<User> inScope = new List<User>(ineligible);
        inScope.add(csms.get('Casey'));
        OnboardingTestDataFactory.limitAssignmentTo(inScope);
        Account account = OnboardingTestDataFactory.createAccount('Contoso');
        List<Opportunity> deals = OnboardingTestDataFactory.createOpenOpportunities(account.Id, 3);

        Test.startTest();
        List<Onboarding__c> created = OnboardingTestDataFactory.createOnboardings(deals);
        Test.stopTest();

        for (Onboarding__c onboarding : [SELECT OwnerId FROM Onboarding__c WHERE Id IN :created]) {
            Assert.areEqual(csms.get('Casey').Id, onboarding.OwnerId, 'Only Casey is an active CSM with capacity');
        }
    }

    @IsTest
    static void sendsOverflowToBacklogAndAlertsManagersOnce() {
        Map<String, User> csms = OnboardingTestDataFactory.createCsms(new Map<String, Integer>{ 'Avery' => 1 });
        Account account = OnboardingTestDataFactory.createAccount('Contoso');
        List<Opportunity> deals = OnboardingTestDataFactory.createOpenOpportunities(account.Id, 3);
        Id backlogQueueId = OnboardingTestDataFactory.getBacklogQueueId();

        Test.startTest();
        List<Onboarding__c> created = OnboardingTestDataFactory.createOnboardings(deals);
        Test.stopTest();

        Map<Id, Integer> countByOwner = countActiveByOwner();
        Assert.areEqual(1, countByOwner.get(csms.get('Avery').Id), 'Avery is filled to capacity');
        Assert.areEqual(2, countByOwner.get(backlogQueueId), 'The rest wait in the backlog queue');
        Assert.areEqual(1, OnboardingAssignmentService.notificationsSent, 'Managers get one alert per transaction, not one per record');
    }

    @IsTest
    static void bulkCloseOf200DealsIsSpreadEvenly() {
        Map<String, User> csms = OnboardingTestDataFactory.createCsms(
            new Map<String, Integer>{ 'Avery' => 100, 'Blake' => 100, 'Casey' => 100 }
        );
        Account account = OnboardingTestDataFactory.createAccount('Contoso');
        List<Opportunity> deals = OnboardingTestDataFactory.createOpenOpportunities(account.Id, 200);

        Test.startTest();
        OnboardingTestDataFactory.closeAsWon(deals); // one DML, like a Data Loader batch
        Test.stopTest();

        Map<Id, Integer> countByOwner = countActiveByOwner();
        Assert.areEqual(67, countByOwner.get(csms.get('Avery').Id));
        Assert.areEqual(67, countByOwner.get(csms.get('Blake').Id));
        Assert.areEqual(66, countByOwner.get(csms.get('Casey').Id));
        Assert.isFalse(countByOwner.containsKey(OnboardingTestDataFactory.getBacklogQueueId()), 'Nothing should be backlogged');
        Assert.areEqual(0, OnboardingAssignmentService.notificationsSent);
    }

    @IsTest
    static void bulkCloseOf200DealsRespectsEachCsmsCapacity() {
        Map<String, User> csms = OnboardingTestDataFactory.createCsms(
            new Map<String, Integer>{ 'Avery' => 4, 'Blake' => 10, 'Casey' => 6 }
        );
        Account account = OnboardingTestDataFactory.createAccount('Contoso');
        List<Opportunity> deals = OnboardingTestDataFactory.createOpenOpportunities(account.Id, 200);

        Test.startTest();
        OnboardingTestDataFactory.closeAsWon(deals);
        Test.stopTest();

        Map<Id, Integer> countByOwner = countActiveByOwner();
        Assert.areEqual(4, countByOwner.get(csms.get('Avery').Id), 'New hire capped at 4');
        Assert.areEqual(10, countByOwner.get(csms.get('Blake').Id), 'Senior CSM capped at 10');
        Assert.areEqual(6, countByOwner.get(csms.get('Casey').Id));
        Assert.areEqual(180, countByOwner.get(OnboardingTestDataFactory.getBacklogQueueId()), 'Everything over capacity is backlogged');
        Assert.areEqual(200, [SELECT COUNT() FROM Onboarding__c], 'Every won deal got exactly one onboarding');
        Assert.areEqual(1, OnboardingAssignmentService.notificationsSent);
    }

    private static Map<Id, Integer> countActiveByOwner() {
        Map<Id, Integer> countByOwner = new Map<Id, Integer>();
        for (AggregateResult row : [SELECT OwnerId ownerId, COUNT(Id) total FROM Onboarding__c WHERE Is_Active__c = TRUE GROUP BY OwnerId]) {
            countByOwner.put((Id) row.get('ownerId'), (Integer) row.get('total'));
        }
        return countByOwner;
    }
}
