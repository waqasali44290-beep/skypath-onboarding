// Simulates the quarter-end Data Loader job: closes open demo deals as won in a single update.
// Change dealsToClose to close fewer (e.g. 6 to show round-robin before anyone hits capacity).

Integer dealsToClose = 200;

String wonStage = [SELECT ApiName FROM OpportunityStage WHERE IsWon = TRUE AND IsActive = TRUE ORDER BY SortOrder LIMIT 1].ApiName;

List<Opportunity> deals = [
    SELECT Id
    FROM Opportunity
    WHERE Name LIKE 'Demo Deal %' AND IsClosed = FALSE
    ORDER BY Name
    LIMIT :dealsToClose
];
for (Opportunity deal : deals) {
    deal.StageName = wonStage;
}
update deals;

String summary = '\nClosed ' + deals.size() + ' deals in one transaction. Active onboardings by owner:\n';
for (AggregateResult row : [
    SELECT Owner.Name ownerName, COUNT(Id) total
    FROM Onboarding__c
    WHERE Is_Active__c = TRUE
    GROUP BY Owner.Name
    ORDER BY Owner.Name
]) {
    summary += '  ' + row.get('ownerName') + ': ' + row.get('total') + '\n';
}
System.debug(LoggingLevel.WARN, summary);
