public with sharing class VisitRelatedListController {
    private static final Integer DEFAULT_PAGE_SIZE = 5;
    private static final Integer MAX_PAGE_SIZE = 25;

    public class VisitListResult {
        @AuraEnabled public List<VisitItem> records;
        @AuraEnabled public Boolean hasMore;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Integer offsetSize;
    }

    public class VisitItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String recordUrl;
        @AuraEnabled public String finalSummary;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Datetime actualVisitStartTime;
        @AuraEnabled public Datetime actualVisitEndTime;
        @AuraEnabled public String status;
        @AuraEnabled public String visitTypeName;
        @AuraEnabled public String visitorName;
        @AuraEnabled public Datetime createdDate;
    }

    @AuraEnabled(cacheable=true)
    public static VisitListResult getVisits(
        Id recordId,
        String objectApiName,
        Integer pageSize,
        Integer offsetSize,
        String sortField,
        String sortDirection
    ) {
        VisitListResult result = new VisitListResult();
        result.records = new List<VisitItem>();
        result.pageSize = normalizePageSize(pageSize);
        result.offsetSize = Math.max(offsetSize == null ? 0 : offsetSize, 0);
        result.hasMore = false;

        Id contactId = resolveContactId(recordId, objectApiName);
        if (contactId == null || !hasObject('Visit') || !hasObject('VisitedParty')) {
            return result;
        }

        String orderByClause = buildOrderByClause(sortField, sortDirection);
        List<String> fields = new List<String>{
            'Id',
            'AccountId',
            'Account.Name',
            'ActualVisitStartTime',
            'ActualVisitEndTime',
            'Status',
            'CreatedDate',
            'Visitor.Name',
            'VisitType.Name'
        };
        if (hasField('Visit', 'Final_Summary__c')) {
            fields.add('Final_Summary__c');
        }

        Integer queryLimit = result.pageSize + 1;
        Integer safeOffset = result.offsetSize;
        String queryText =
            'SELECT ' +
            String.join(fields, ', ') +
            ' FROM Visit WHERE Id IN (' +
            'SELECT VisitId FROM VisitedParty WHERE ContactId = :contactId' +
            ') ORDER BY ' +
            orderByClause +
            ' LIMIT :queryLimit OFFSET :safeOffset';

        List<SObject> rows = Database.query(queryText);
        result.hasMore = rows.size() > result.pageSize;

        Integer visibleCount = Math.min(rows.size(), result.pageSize);
        for (Integer index = 0; index < visibleCount; index++) {
            result.records.add(toVisitItem(rows[index]));
        }

        return result;
    }

    private static VisitItem toVisitItem(SObject row) {
        VisitItem item = new VisitItem();
        item.id = (Id) row.get('Id');
        item.recordUrl = '/lightning/r/Visit/' + String.valueOf(item.id) + '/view';
        item.accountId = (Id) row.get('AccountId');
        item.actualVisitStartTime = (Datetime) row.get('ActualVisitStartTime');
        item.actualVisitEndTime = (Datetime) row.get('ActualVisitEndTime');
        item.status = (String) row.get('Status');
        item.createdDate = (Datetime) row.get('CreatedDate');

        if (hasField('Visit', 'Final_Summary__c')) {
            item.finalSummary = (String) row.get('Final_Summary__c');
        }

        SObject visitType = row.getSObject('VisitType');
        item.visitTypeName = visitType == null ? null : (String) visitType.get('Name');

        SObject account = row.getSObject('Account');
        item.accountName = account == null ? null : (String) account.get('Name');

        SObject visitor = row.getSObject('Visitor');
        item.visitorName = visitor == null ? null : (String) visitor.get('Name');
        return item;
    }

    private static Id resolveContactId(Id recordId, String objectApiName) {
        if (recordId == null) {
            return null;
        }

        String normalizedObjectName = String.isBlank(objectApiName) ? null : objectApiName.trim();
        if (normalizedObjectName == 'Contact' || recordId.getSObjectType() == Contact.SObjectType) {
            return recordId;
        }

        if (normalizedObjectName == 'Account' || recordId.getSObjectType() == Account.SObjectType) {
            try {
                List<SObject> accounts = Database.query(
                    'SELECT Id, IsPersonAccount, PersonContactId FROM Account WHERE Id = :recordId LIMIT 1'
                );
                if (!accounts.isEmpty() && (Boolean) accounts[0].get('IsPersonAccount') == true) {
                    return (Id) accounts[0].get('PersonContactId');
                }
            } catch (Exception ex) {
                return null;
            }
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
            'ActualVisitStartTime' => 'ActualVisitStartTime',
            'ActualVisitEndTime' => 'ActualVisitEndTime',
            'Status' => 'Status',
            'Account.Name' => 'Account.Name',
            'Visitor.Name' => 'Visitor.Name',
            'VisitType.Name' => 'VisitType.Name'
        };

        String fieldName = sortableFields.containsKey(sortField) ? sortableFields.get(sortField) : 'CreatedDate';
        String direction = String.valueOf(sortDirection).equalsIgnoreCase('ASC') ? 'ASC' : 'DESC';
        String primarySort = fieldName + ' ' + direction + ' NULLS LAST';
        return fieldName == 'CreatedDate' ? primarySort : primarySort + ', CreatedDate DESC';
    }

    private static Boolean hasObject(String objectApiName) {
        return Schema.getGlobalDescribe().containsKey(objectApiName);
    }

    private static Boolean hasField(String objectApiName, String fieldApiName) {
        if (!hasObject(objectApiName)) {
            return false;
        }
        return Schema.getGlobalDescribe().get(objectApiName).getDescribe().fields.getMap().containsKey(fieldApiName);
    }
}