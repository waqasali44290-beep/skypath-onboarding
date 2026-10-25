/**
 * Test data for onboarding tests. Stage names and profiles are looked up, never hardcoded,
 * so the tests run in any org.
 */
@IsTest
public class OnboardingTestDataFactory {
    public static final List<String> STAGE_ORDER = new List<String>{
        'Kickoff_Scheduled',
        'Gathering_Info',
        'Implementation',
        'QA_Review',
        'Go_Live',
        'Post_Launch_Review'
    };

    /**
     * Real CSMs configured in the org would skew assignment results, so tests switch them off.
     * The change is rolled back with the rest of the test.
     */
    public static void removeExistingCsms() {
        List<User> csms = [SELECT Id FROM User WHERE Is_CSM__c = TRUE];
        for (User csm : csms) {
            csm.Is_CSM__c = false;
        }
        update csms;
    }

    /** Creates users as the running user so setup-object DML doesn't mix with the test's other DML. */
    public static Map<String, User> createCsms(Map<String, Integer> capacityByLastName) {
        Map<String, User> csmsByLastName = new Map<String, User>();
        for (String lastName : capacityByLastName.keySet()) {
            csmsByLastName.put(lastName, buildUser(lastName, true, capacityByLastName.get(lastName)));
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            removeExistingCsms();
            insert csmsByLastName.values();
        }
        return csmsByLastName;
    }

    public static User buildUser(String lastName, Boolean isCsm, Integer maxActiveOnboardings) {
        String uniqueKey = lastName.toLowerCase() + '.' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(10);
        return new User(
            FirstName = 'Test',
            LastName = lastName,
            Alias = lastName.left(8),
            Email = uniqueKey + '@example.com',
            Username = uniqueKey + '@skypath-onboarding.test',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            Is_CSM__c = isCsm,
            Max_Active_Onboardings__c = maxActiveOnboardings
        );
    }

    public static Account createAccount(String name) {
        Account account = new Account(Name = name);
        insert account;
        return account;
    }

    public static List<Opportunity> createOpenOpportunities(Id accountId, Integer count) {
        String openStage = getOpenStageName();
        List<Opportunity> opportunities = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opportunities.add(
                new Opportunity(Name = 'Test Deal ' + i, AccountId = accountId, StageName = openStage, CloseDate = Date.today().addDays(7))
            );
        }
        insert opportunities;
        return opportunities;
    }

    /** Inserts onboardings directly (no deal closure), which fires CSM assignment. */
    public static List<Onboarding__c> createOnboardings(List<Opportunity> opportunities) {
        List<Onboarding__c> onboardings = new List<Onboarding__c>();
        for (Opportunity opportunity : opportunities) {
            onboardings.add(
                new Onboarding__c(
                    Name = opportunity.Name,
                    Opportunity__c = opportunity.Id,
                    Stage__c = 'Kickoff_Scheduled',
                    Target_Go_Live_Date__c = Date.today().addDays(45)
                )
            );
        }
        insert onboardings;
        return onboardings;
    }

    public static void closeAsWon(List<Opportunity> opportunities) {
        String wonStage = getWonStageName();
        for (Opportunity opportunity : opportunities) {
            opportunity.StageName = wonStage;
        }
        update opportunities;
    }

    /** Walks an onboarding forward one stage at a time, filling in required notes on the way. */
    public static void advanceTo(Id onboardingId, String targetStage) {
        Onboarding__c onboarding = [SELECT Id, Stage__c FROM Onboarding__c WHERE Id = :onboardingId];
        Integer current = STAGE_ORDER.indexOf(onboarding.Stage__c);
        Integer target = STAGE_ORDER.indexOf(targetStage);
        for (Integer i = current + 1; i <= target; i++) {
            update new Onboarding__c(
                Id = onboardingId,
                Stage__c = STAGE_ORDER[i],
                Gathering_Info_Notes__c = 'Requirements captured in kickoff workshop.',
                Implementation_Notes__c = 'SSO and data import configured.'
            );
        }
    }

    public static Id getBacklogQueueId() {
        String queueName = Onboarding_Setting__mdt.getInstance('Default').Backlog_Queue_Name__c;
        return [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :queueName].Id;
    }

    public static String getWonStageName() {
        return [SELECT ApiName FROM OpportunityStage WHERE IsWon = TRUE AND IsActive = TRUE ORDER BY SortOrder LIMIT 1].ApiName;
    }

    public static String getOpenStageName() {
        return [SELECT ApiName FROM OpportunityStage WHERE IsClosed = FALSE AND IsActive = TRUE ORDER BY SortOrder LIMIT 1].ApiName;
    }
}
