public with sharing class ExpenseRelatedListController {
    private static final Integer DEFAULT_PAGE_SIZE = 5;
    private static final Integer MAX_PAGE_SIZE = 25;

    public class ExpenseListResult {
        @AuraEnabled public List<ExpenseItem> records;
        @AuraEnabled public Boolean hasMore;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Integer offsetSize;
    }

    public class ExpenseItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String recordUrl;
        @AuraEnabled public String title;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Id contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String visitIdText;
        @AuraEnabled public String visitName;
        @AuraEnabled public String visitUrl;
        @AuraEnabled public String expenseType;
        @AuraEnabled public Date transactionDate;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Datetime createdDate;
    }

    @AuraEnabled(cacheable=true)
    public static ExpenseListResult getExpenses(
        Id recordId,
        String objectApiName,
        Integer pageSize,
        Integer offsetSize,
        String sortField,
        String sortDirection
    ) {
        ExpenseListResult result = new ExpenseListResult();
        result.records = new List<ExpenseItem>();
        result.pageSize = normalizePageSize(pageSize);
        result.offsetSize = Math.max(offsetSize == null ? 0 : offsetSize, 0);
        result.hasMore = false;

        FilterContext filterContext = resolveFilterContext(recordId, objectApiName);
        if (filterContext == null || !hasObject('Expense')) {
            return result;
        }

        String whereClause = filterContext.whereClause;
        String orderByClause = buildOrderByClause(sortField, sortDirection);
        Integer queryLimit = result.pageSize + 1;
        Integer safeOffset = result.offsetSize;

        String queryText =
            'SELECT Id, Title, AccountId, Account.Name, Contact__c, Contact__r.Name, Visit__c, ' +
            'ExpenseType, TransactionDate, Amount, CreatedDate ' +
            'FROM Expense WHERE ' +
            whereClause +
            ' ORDER BY ' +
            orderByClause +
            ' LIMIT :queryLimit OFFSET :safeOffset';

        List<Expense> rows = Database.query(queryText);
        result.hasMore = rows.size() > result.pageSize;

        Set<Id> visitIds = new Set<Id>();
        Integer visibleCount = Math.min(rows.size(), result.pageSize);
        for (Integer index = 0; index < visibleCount; index++) {
            Id visitId = toVisitId(rows[index].Visit__c);
            if (visitId != null) {
                visitIds.add(visitId);
            }
        }

        Map<Id, String> visitNamesById = fetchVisitNames(visitIds);
        for (Integer index = 0; index < visibleCount; index++) {
            result.records.add(toExpenseItem(rows[index], visitNamesById));
        }

        return result;
    }

    private static ExpenseItem toExpenseItem(Expense row, Map<Id, String> visitNamesById) {
        ExpenseItem item = new ExpenseItem();
        item.id = row.Id;
        item.recordUrl = '/lightning/r/Expense/' + String.valueOf(row.Id) + '/view';
        item.title = row.Title;
        item.accountId = row.AccountId;
        item.accountName = row.Account == null ? null : row.Account.Name;
        item.contactId = row.Contact__c;
        item.contactName = row.Contact__r == null ? null : row.Contact__r.Name;
        item.visitIdText = row.Visit__c;
        item.expenseType = row.ExpenseType;
        item.transactionDate = row.TransactionDate;
        item.amount = row.Amount;
        item.createdDate = row.CreatedDate;

        Id visitId = toVisitId(row.Visit__c);
        if (visitId != null) {
            item.visitUrl = '/lightning/r/Visit/' + String.valueOf(visitId) + '/view';
            item.visitName = visitNamesById.containsKey(visitId) ? visitNamesById.get(visitId) : String.valueOf(visitId);
        }

        return item;
    }

    private static Map<Id, String> fetchVisitNames(Set<Id> visitIds) {
        Map<Id, String> visitNamesById = new Map<Id, String>();
        if (visitIds.isEmpty() || !hasObject('Visit')) {
            return visitNamesById;
        }

        for (Visit visitRecord : [SELECT Id, Name FROM Visit WHERE Id IN :visitIds]) {
            visitNamesById.put(visitRecord.Id, visitRecord.Name);
        }
        return visitNamesById;
    }

    private static Id toVisitId(String visitIdText) {
        if (String.isBlank(visitIdText)) {
            return null;
        }

        try {
            Id candidateId = Id.valueOf(visitIdText.trim());
            return candidateId.getSObjectType() == Visit.SObjectType ? candidateId : null;
        } catch (Exception ex) {
            return null;
        }
    }

    private class FilterContext {
        public String whereClause;

        public FilterContext(String whereClause) {
            this.whereClause = whereClause;
        }
    }

    private static FilterContext resolveFilterContext(Id recordId, String objectApiName) {
        if (recordId == null) {
            return null;
        }

        String normalizedObjectName = String.isBlank(objectApiName) ? null : objectApiName.trim();
        if (normalizedObjectName == 'Contact' || recordId.getSObjectType() == Contact.SObjectType) {
            return new FilterContext('Contact__c = ' + toSoqlIdLiteral(recordId));
        }

        if (normalizedObjectName == 'Visit' || recordId.getSObjectType() == Visit.SObjectType) {
            return new FilterContext('Visit__c = ' + toSoqlStringLiteral(String.valueOf(recordId)));
        }

        if (normalizedObjectName == 'Account' || recordId.getSObjectType() == Account.SObjectType) {
            Id personContactId = resolvePersonContactId(recordId);
            if (personContactId != null) {
                return new FilterContext('Contact__c = ' + toSoqlIdLiteral(personContactId));
            }
            return new FilterContext('AccountId = ' + toSoqlIdLiteral(recordId));
        }

        return null;
    }

    private static String toSoqlIdLiteral(Id recordId) {
        return toSoqlStringLiteral(String.valueOf(recordId));
    }

    private static String toSoqlStringLiteral(String value) {
        return '\'' + String.escapeSingleQuotes(value) + '\'';
    }

    private static Id resolvePersonContactId(Id accountId) {
        try {
            List<SObject> accounts = Database.query(
                'SELECT Id, IsPersonAccount, PersonContactId FROM Account WHERE Id = :accountId LIMIT 1'
            );
            if (!accounts.isEmpty() && (Boolean) accounts[0].get('IsPersonAccount') == true) {
                return (Id) accounts[0].get('PersonContactId');
            }
        } catch (Exception ex) {
            return null;
        }
        return null;
    }

    private static Integer normalizePageSize(Integer pageSize) {
        if (pageSize == null || pageSize <= 0) {
            return DEFAULT_PAGE_SIZE;
        }
        return Math.min(pageSize, MAX_PAGE_SIZE);
    }

    private static String buildOrderByClause(String sortField, String sortDirection) {
        Map<String, String> sortableFields = new Map<String, String>{
            'CreatedDate' => 'CreatedDate',
            'TransactionDate' => 'TransactionDate',
            'Amount' => 'Amount',
            'ExpenseType' => 'ExpenseType',
            'Title' => 'Title',
            'Account.Name' => 'Account.Name',
            'Contact__r.Name' => 'Contact__r.Name'
        };

        String fieldName = sortableFields.containsKey(sortField) ? sortableFields.get(sortField) : 'CreatedDate';
        String direction = String.valueOf(sortDirection).equalsIgnoreCase('ASC') ? 'ASC' : 'DESC';
        String primarySort = fieldName + ' ' + direction + ' NULLS LAST';
        return fieldName == 'CreatedDate' ? primarySort : primarySort + ', CreatedDate DESC';
    }

    private static Boolean hasObject(String objectApiName) {
        return Schema.getGlobalDescribe().containsKey(objectApiName);
    }
}