// Post-deploy setup for a demo org. Safe to run more than once.
// Run `sf org assign permset --name Onboarding_Admin` first, otherwise the User CSM fields
// aren't visible to anonymous Apex and this won't compile.
//  - creates two demo CSMs with different capacities (a new hire and a senior CSM)
//  - gives the CSMs the Onboarding - CSM permission set
//  - makes the running user an onboarding admin and a member of the CS Managers group
//
// A Developer Edition org only has a couple of spare user licences, so the demo uses two CSMs.
// More CSMs are added the same way in a real org: tick "CSM" on the user and set their capacity.

String orgKey = UserInfo.getOrganizationId().left(15).toLowerCase();
Map<String, Integer> capacityByName = new Map<String, Integer>{ 'Jordan Reyes' => 4, 'Sam Patel' => 10 };

// Prefer Salesforce Platform licences (enough for working onboardings), fall back to full licences.
Profile csmProfile;
for (Profile candidate : [
    SELECT Id, Name, UserLicense.TotalLicenses, UserLicense.UsedLicenses
    FROM Profile
    WHERE Name IN ('Standard Platform User', 'Standard User')
]) {
    Integer free = candidate.UserLicense.TotalLicenses - candidate.UserLicense.UsedLicenses;
    if (free >= capacityByName.size() && (csmProfile == null || candidate.Name == 'Standard Platform User')) {
        csmProfile = candidate;
    }
}

Map<String, User> existing = new Map<String, User>();
for (User u : [SELECT Id, Username FROM User WHERE Username LIKE :('%.' + orgKey + '@skypath-demo.com')]) {
    existing.put(u.Username, u);
}

List<User> csms = new List<User>();
for (String fullName : capacityByName.keySet()) {
    String firstName = fullName.substringBefore(' ');
    String lastName = fullName.substringAfter(' ');
    String username = (firstName + '.' + lastName + '.' + orgKey + '@skypath-demo.com').toLowerCase();
    User csm = existing.get(username);
    if (csm == null) {
        if (csmProfile == null) {
            throw new IllegalArgumentException('Not enough free user licences for the demo CSMs. Free up two licences or create the users by hand.');
        }
        csm = new User(
            FirstName = firstName,
            LastName = lastName,
            Alias = (firstName.left(1) + lastName).left(8).toLowerCase(),
            Username = username,
            Email = UserInfo.getUserEmail(),
            ProfileId = csmProfile.Id,
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_GB',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
    csm.Is_CSM__c = true;
    csm.Max_Active_Onboardings__c = capacityByName.get(fullName);
    csms.add(csm);
}
List<User> newCsms = new List<User>();
List<User> existingCsms = new List<User>();
for (User csm : csms) {
    (csm.Id == null ? newCsms : existingCsms).add(csm);
}
insert newCsms;
update existingCsms;

Map<String, Id> permissionSetIds = new Map<String, Id>();
for (PermissionSet ps : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('Onboarding_CSM', 'Onboarding_Admin')]) {
    permissionSetIds.put(ps.Name, ps.Id);
}

Set<String> alreadyAssigned = new Set<String>();
for (PermissionSetAssignment psa : [
    SELECT AssigneeId, PermissionSetId
    FROM PermissionSetAssignment
    WHERE PermissionSetId IN :permissionSetIds.values()
]) {
    alreadyAssigned.add('' + psa.AssigneeId + psa.PermissionSetId);
}

List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
for (User csm : csms) {
    if (!alreadyAssigned.contains('' + csm.Id + permissionSetIds.get('Onboarding_CSM'))) {
        assignments.add(new PermissionSetAssignment(AssigneeId = csm.Id, PermissionSetId = permissionSetIds.get('Onboarding_CSM')));
    }
}
if (!alreadyAssigned.contains('' + UserInfo.getUserId() + permissionSetIds.get('Onboarding_Admin'))) {
    assignments.add(new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = permissionSetIds.get('Onboarding_Admin')));
}
insert assignments;

Group managers = [SELECT Id FROM Group WHERE Type = 'Regular' AND DeveloperName = 'CS_Managers'];
if ([SELECT COUNT() FROM GroupMember WHERE GroupId = :managers.Id AND UserOrGroupId = :UserInfo.getUserId()] == 0) {
    insert new GroupMember(GroupId = managers.Id, UserOrGroupId = UserInfo.getUserId());
}

System.debug(LoggingLevel.WARN, 'Demo CSMs ready on profile ' + (csmProfile == null ? '(existing users)' : csmProfile.Name) + ': ' + capacityByName);
