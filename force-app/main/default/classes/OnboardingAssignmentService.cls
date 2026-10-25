/**
 * Assigns new onboardings to the eligible CSM with the fewest active onboardings.
 *
 * Eligible CSM:       active user with User.Is_CSM__c = true and User.Max_Active_Onboardings__c > 0.
 * Active onboarding:  Onboarding__c.Is_Active__c (any stage before Post-Launch Review).
 * Nobody has room:    the onboarding goes to the backlog queue and the CS managers group is notified.
 *
 * Workload is loaded once per transaction and updated in memory as each record is assigned,
 * so a 200-record batch is spread the same way 200 single inserts would be, and capacity holds.
 *
 * Runs without sharing on purpose: workload has to be counted across the whole team,
 * not only the onboardings visible to whoever closed the deal.
 */
public without sharing class OnboardingAssignmentService {
    public class ConfigurationException extends Exception {
    }

    @TestVisible
    private static final String SETTING_NAME = 'Default';

    @TestVisible
    private static final String BACKLOG_LIST_VIEW = 'Onboarding_Backlog';

    @TestVisible
    private static Integer notificationsSent = 0;

    private static Onboarding_Setting__mdt cachedSettings;
    private static Id cachedBacklogQueueId;

    public static void assignOwners(List<Onboarding__c> onboardings) {
        List<CsmWorkload> csms = loadCsmWorkloads();

        for (Onboarding__c onboarding : onboardings) {
            CsmWorkload csm = findLeastLoaded(csms);
            if (csm == null) {
                onboarding.OwnerId = getBacklogQueueId();
            } else {
                onboarding.OwnerId = csm.userId;
                csm.activeCount++;
            }
        }
    }

    public static void notifyManagersOfBacklog(List<Onboarding__c> onboardings) {
        List<Onboarding__c> backlogged = new List<Onboarding__c>();
        for (Onboarding__c onboarding : onboardings) {
            if (onboarding.OwnerId.getSobjectType() == Group.SObjectType && onboarding.OwnerId == getBacklogQueueId()) {
                backlogged.add(onboarding);
            }
        }
        if (backlogged.isEmpty()) {
            return;
        }

        Onboarding_Setting__mdt settings = getSettings();
        List<Group> managerGroups = [
            SELECT Id
            FROM Group
            WHERE Type = 'Regular' AND DeveloperName = :settings.Manager_Group_Name__c
            LIMIT 1
        ];
        List<CustomNotificationType> notificationTypes = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :settings.Backlog_Notification_Type__c
            LIMIT 1
        ];
        if (managerGroups.isEmpty() || notificationTypes.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'Backlog alert skipped: manager group or notification type not found. Check Onboarding Setting "' + SETTING_NAME + '".');
            return;
        }

        // One alert per transaction rather than one per record, so a quarter-end bulk close
        // doesn't bury the managers in 200 identical notifications.
        Integer count = backlogged.size();
        Messaging.CustomNotification alert = new Messaging.CustomNotification();
        alert.setNotificationTypeId(notificationTypes[0].Id);
        alert.setTitle(count == 1 ? 'New onboarding in the backlog' : count + ' new onboardings in the backlog');
        alert.setBody(
            'Every CSM is at capacity, so ' +
                (count == 1 ? backlogged[0].Name + ' was' : count + ' onboardings were') +
                ' added to the Onboarding Backlog queue and need an owner.'
        );
        if (count == 1) {
            alert.setTargetId(backlogged[0].Id);
        } else {
            alert.setTargetPageRef(
                JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'standard__objectPage',
                        'attributes' => new Map<String, Object>{ 'objectApiName' => 'Onboarding__c', 'actionName' => 'list' },
                        'state' => new Map<String, Object>{ 'filterName' => BACKLOG_LIST_VIEW }
                    }
                )
            );
        }

        // A failed alert must not stop deals from closing. The backlog list view is still the
        // source of truth for managers, so log and carry on.
        try {
            alert.send(new Set<String>{ managerGroups[0].Id });
            notificationsSent++;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Backlog alert failed: ' + e.getMessage());
        }
    }

    private static List<CsmWorkload> loadCsmWorkloads() {
        Map<Id, CsmWorkload> workloadByUserId = new Map<Id, CsmWorkload>();
        for (User csm : [
            SELECT Id, Name, Max_Active_Onboardings__c
            FROM User
            WHERE Is_CSM__c = TRUE AND IsActive = TRUE AND Max_Active_Onboardings__c > 0
        ]) {
            workloadByUserId.put(csm.Id, new CsmWorkload(csm));
        }
        if (workloadByUserId.isEmpty()) {
            return new List<CsmWorkload>();
        }

        // Counted from locked rows rather than an aggregate query: FOR UPDATE makes a second
        // assignment run (e.g. a parallel Data Loader batch) wait until this one commits, so two
        // transactions can't both hand out a CSM's last free slot. User rows can't be locked,
        // and aggregate queries can't use FOR UPDATE, hence this shape.
        Set<Id> csmIds = workloadByUserId.keySet();
        for (Onboarding__c active : [
            SELECT OwnerId
            FROM Onboarding__c
            WHERE Is_Active__c = TRUE AND OwnerId IN :csmIds
            FOR UPDATE
        ]) {
            workloadByUserId.get(active.OwnerId).activeCount++;
        }

        List<CsmWorkload> workloads = workloadByUserId.values();
        workloads.sort();
        return workloads;
    }

    // Lowest active count wins. The list is sorted by name, so ties go to the same CSM
    // every time and a batch is dealt out round-robin.
    private static CsmWorkload findLeastLoaded(List<CsmWorkload> csms) {
        CsmWorkload leastLoaded;
        for (CsmWorkload csm : csms) {
            if (csm.hasCapacity() && (leastLoaded == null || csm.activeCount < leastLoaded.activeCount)) {
                leastLoaded = csm;
            }
        }
        return leastLoaded;
    }

    private static Id getBacklogQueueId() {
        if (cachedBacklogQueueId == null) {
            String queueName = getSettings().Backlog_Queue_Name__c;
            List<Group> queues = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :queueName LIMIT 1];
            if (queues.isEmpty()) {
                throw new ConfigurationException(
                    'Onboarding backlog queue "' + queueName + '" was not found. Check Onboarding Setting "' + SETTING_NAME + '".'
                );
            }
            cachedBacklogQueueId = queues[0].Id;
        }
        return cachedBacklogQueueId;
    }

    private static Onboarding_Setting__mdt getSettings() {
        if (cachedSettings == null) {
            cachedSettings = Onboarding_Setting__mdt.getInstance(SETTING_NAME);
            if (cachedSettings == null) {
                throw new ConfigurationException('Onboarding Setting "' + SETTING_NAME + '" is missing.');
            }
        }
        return cachedSettings;
    }

    private class CsmWorkload implements Comparable {
        final Id userId;
        final String name;
        final Integer maxActive;
        Integer activeCount = 0;

        CsmWorkload(User csm) {
            userId = csm.Id;
            name = csm.Name;
            maxActive = csm.Max_Active_Onboardings__c.intValue();
        }

        Boolean hasCapacity() {
            return activeCount < maxActive;
        }

        public Integer compareTo(Object other) {
            CsmWorkload that = (CsmWorkload) other;
            Integer byName = name.compareTo(that.name);
            return byName != 0 ? byName : String.valueOf(userId).compareTo(String.valueOf(that.userId));
        }
    }
}
