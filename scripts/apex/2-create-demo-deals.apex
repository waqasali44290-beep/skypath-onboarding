// Creates 10 demo customers and 200 open demo deals, ready for the quarter-end bulk close.
// Run 4-reset-demo-data.apex first if you want to start over.

List<String> customers = new List<String>{
    'Northwind Logistics', 'Bluebird Health', 'Kestrel Energy', 'Harbor Analytics', 'Summit Retail',
    'Ironwood Manufacturing', 'Lumen Education', 'Cobalt Insurance', 'Meridian Travel', 'Orchard Foods'
};

List<Account> accounts = new List<Account>();
for (String name : customers) {
    accounts.add(new Account(Name = name));
}
insert accounts;

String openStage = [SELECT ApiName FROM OpportunityStage WHERE IsClosed = FALSE AND IsActive = TRUE ORDER BY SortOrder LIMIT 1].ApiName;

List<Opportunity> deals = new List<Opportunity>();
for (Integer i = 1; i <= 200; i++) {
    Account account = accounts[Math.mod(i - 1, accounts.size())];
    deals.add(
        new Opportunity(
            Name = 'Demo Deal ' + String.valueOf(i).leftPad(3, '0') + ' - ' + account.Name,
            AccountId = account.Id,
            StageName = openStage,
            CloseDate = Date.today(),
            Amount = 12000 + Math.mod(i * 1500, 60000)
        )
    );
}
insert deals;

System.debug(LoggingLevel.WARN, 'Created ' + accounts.size() + ' customers and ' + deals.size() + ' open demo deals.');
