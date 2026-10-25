// Removes the demo deals, their onboardings (stage history goes with them) and the demo customers.
// Onboardings are deleted first because a deal can't be deleted while its onboarding exists.

delete [SELECT Id FROM Onboarding__c WHERE Opportunity__r.Name LIKE 'Demo Deal %'];
delete [SELECT Id FROM Opportunity WHERE Name LIKE 'Demo Deal %'];
delete [SELECT Id FROM Account WHERE Id NOT IN (SELECT AccountId FROM Opportunity) AND Name IN (
    'Northwind Logistics', 'Bluebird Health', 'Kestrel Energy', 'Harbor Analytics', 'Summit Retail',
    'Ironwood Manufacturing', 'Lumen Education', 'Cobalt Insurance', 'Meridian Travel', 'Orchard Foods'
)];

System.debug(LoggingLevel.WARN, 'Demo data removed.');
