public with sharing class VisitFinalizeAction {
    public class Request {
        @InvocableVariable(label='Visit ID' description='ID of the Visit record to finalize. Must be a valid Visit ID that exists in the system.')
        public String visitId;
        
        @InvocableVariable(label='Final Summary' description='Final summary text of the visit to be stored in Final_Summary__c field and used to create a summary artifact. Also analyzed for follow-up and referral keywords.')
        public String finalSummary;
        
        @InvocableVariable(label='Language Code' description='Language code to store in Agent_Language_Code__c field on Visit and Language_Code__c on the created summary artifact.')
        public String languageCode;
        
        @InvocableVariable(label='Rep Confirmed' description='Must be true to proceed with finalization. Acts as a gate to ensure representative has confirmed visit details before finalizing.')
        public Boolean repConfirmed;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True if visit was finalized successfully. False for errors, validation failures, or missing confirmation.')
        public Boolean success;
        
        @InvocableVariable(label='Status Code' description='Finalization status: Finalized (success), REQUIRES_CONFIRMATION (rep not confirmed), INVALID_INPUT (missing/invalid visitId), NOT_FOUND (visit not found), CONFIG_ERROR (Visit object unavailable), ERROR (exception).')
        public String statusCode;
        
        @InvocableVariable(label='User Message' description='Human-readable message describing the finalization outcome or error details.')
        public String userMessage;
        
        @InvocableVariable(label='Visit ID' description='Echo of the input visitId for reference and downstream processing.')
        public String visitId;
        
        @InvocableVariable(label='Final Artifact ID' description='ID of the Visit_Artifact__c record created with type "Summary" containing the final summary text. Null if artifact creation failed or object unavailable.')
        public String finalArtifactId;

    }

    @InvocableMethod(label='Visit Finalize Action' description='Finalizes a draft visit after rep confirmation and returns downstream recommendation flags.')
    public static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request requestItem : requests) {
            responses.add(finalizeOne(requestItem));
        }
        return responses;
    }

    private static Response finalizeOne(Request requestItem) {
        Response responseItem = new Response();
        responseItem.success = false;

        if (requestItem == null) {
            responseItem.statusCode = 'INVALID_INPUT';
            responseItem.userMessage = 'Request payload is required.';
            return responseItem;
        }

        responseItem.visitId = requestItem.visitId;
        Id typedVisitId = toId(requestItem.visitId);
        if (typedVisitId == null) {
            responseItem.statusCode = 'INVALID_INPUT';
            responseItem.userMessage = 'A valid visitId is required.';
            return responseItem;
        }

        try {
            List<SObject> visitRows = Database.query(
                'SELECT Id FROM Visit WHERE Id = \'' +
                String.escapeSingleQuotes(String.valueOf(typedVisitId)) +
                '\' LIMIT 1'
            );
            if (visitRows.isEmpty()) {
                responseItem.statusCode = 'NOT_FOUND';
                responseItem.userMessage = 'Visit not found for the provided visitId.';
                return responseItem;
            }

            SObject visitRecord = visitRows[0];
            applyFinalizeFields(visitRecord, requestItem);
            update visitRecord;

            Id finalArtifactId = createFinalArtifact(typedVisitId, requestItem);

            String finalSummary = String.isBlank(requestItem.finalSummary) ? '' : requestItem.finalSummary.toLowerCase();
            responseItem.finalArtifactId = finalArtifactId == null ? null : String.valueOf(finalArtifactId);
            responseItem.success = true;
            responseItem.statusCode = 'Finalized';
            responseItem.userMessage = 'Visit finalized successfully.';
        } catch (Exception ex) {
            responseItem.success = false;
            responseItem.statusCode = 'ERROR';
            responseItem.userMessage = ex.getMessage();
        }

        return responseItem;
    }

    private static void applyFinalizeFields(SObject visitRecord, Request requestItem) {
        setFieldIfPresent(visitRecord, 'Visit', 'Final_Summary__c', requestItem.finalSummary);
        setFieldIfPresent(visitRecord, 'Visit', 'Agent_Language_Code__c', requestItem.languageCode);

        if (hasField('Visit', 'Summary_Confidence__c')) {
            Decimal confidence = String.isBlank(requestItem.finalSummary) ? 0.8 : 0.98;
            visitRecord.put('Summary_Confidence__c', confidence);
        }

        Map<String, Schema.SObjectField> visitFields = fieldMapFor('Visit');
        String statusField = firstExisting(visitFields, new List<String>{ 'Status', 'Status__c', 'Visit_Status__c' });
        if (statusField != null) {
            String bestStatus = pickBestStatusValue(visitFields.get(statusField).getDescribe());
            if (bestStatus != null) {
                visitRecord.put(statusField, bestStatus);
            }
        }
    }

    private static String pickBestStatusValue(Schema.DescribeFieldResult statusDescribe) {
        if (statusDescribe == null) {
            return null;
        }
        if (statusDescribe.getType() != Schema.DisplayType.Picklist) {
            return 'Finalized';
        }

        List<String> preferred = new List<String>{ 'Finalized', 'Completed', 'Closed', 'Done' };
        Set<String> available = new Set<String>();
        for (Schema.PicklistEntry entry : statusDescribe.getPicklistValues()) {
            available.add(entry.getValue());
        }

        for (String candidate : preferred) {
            if (available.contains(candidate)) {
                return candidate;
            }
        }
        return statusDescribe.getPicklistValues().isEmpty() ? null : statusDescribe.getPicklistValues()[0].getValue();
    }

    private static Id createFinalArtifact(Id visitId, Request requestItem) {
        if (visitId == null || !Schema.getGlobalDescribe().containsKey('Visit_Artifact__c')) {
            return null;
        }

        SObject artifact = Schema.getGlobalDescribe().get('Visit_Artifact__c').newSObject();
        artifact.put('Visit__c', visitId);
        artifact.put('Artifact_Type__c', 'Summary');
        setFieldIfPresent(artifact, 'Visit_Artifact__c', 'Normalized_Text__c', requestItem.finalSummary);
        setFieldIfPresent(artifact, 'Visit_Artifact__c', 'Language_Code__c', requestItem.languageCode);
        if (isAllowedPicklistValue('Visit_Artifact__c', 'Source_Channel__c', 'SalesforceMobile')) {
            artifact.put('Source_Channel__c', 'SalesforceMobile');
        }

        insert artifact;
        return (Id) artifact.get('Id');
    }

    private static Boolean isReferralRequiredFromMapping(Id visitId) {
        if (visitId == null || !Schema.getGlobalDescribe().containsKey('Agent_Work_Type_Mapping__mdt')) {
            return false;
        }

        String workTypeDeveloperName = resolveWorkTypeDeveloperName(visitId);
        if (String.isBlank(workTypeDeveloperName)) {
            return false;
        }

        try {
            List<SObject> rows = Database.query(
                'SELECT Requires_Referral_Check__c FROM Agent_Work_Type_Mapping__mdt WHERE Work_Type_DeveloperName__c = \'' +
                String.escapeSingleQuotes(workTypeDeveloperName) +
                '\' LIMIT 1'
            );
            if (rows.isEmpty()) {
                return false;
            }
            Object value = rows[0].get('Requires_Referral_Check__c');
            return value instanceof Boolean && (Boolean) value;
        } catch (Exception ex) {
            return false;
        }
    }

    private static String resolveWorkTypeDeveloperName(Id visitId) {
        if (visitId == null || !Schema.getGlobalDescribe().containsKey('Visit')) {
            return null;
        }

        Map<String, Schema.SObjectField> visitFields = fieldMapFor('Visit');
        String workTypeLookup = firstExisting(visitFields, new List<String>{ 'WorkTypeId', 'WorkType__c' });
        if (workTypeLookup == null || !Schema.getGlobalDescribe().containsKey('WorkType')) {
            return null;
        }

        try {
            List<SObject> visitRows = Database.query(
                'SELECT ' +
                workTypeLookup +
                ' FROM Visit WHERE Id = \'' +
                String.escapeSingleQuotes(String.valueOf(visitId)) +
                '\' LIMIT 1'
            );
            if (visitRows.isEmpty() || visitRows[0].get(workTypeLookup) == null) {
                return null;
            }

            String workTypeId = String.valueOf(visitRows[0].get(workTypeLookup));
            List<SObject> workTypes = Database.query(
                'SELECT DeveloperName FROM WorkType WHERE Id = \'' +
                String.escapeSingleQuotes(workTypeId) +
                '\' LIMIT 1'
            );
            return workTypes.isEmpty() ? null : String.valueOf(workTypes[0].get('DeveloperName'));
        } catch (Exception ex) {
            return null;
        }
    }

    private static Boolean containsAny(String haystack, List<String> terms) {
        if (String.isBlank(haystack) || terms == null || terms.isEmpty()) {
            return false;
        }
        for (String term : terms) {
            if (!String.isBlank(term) && haystack.contains(term)) {
                return true;
            }
        }
        return false;
    }

    private static Id toId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return (Id) value;
        } catch (Exception ex) {
            return null;
        }
    }

    private static void setFieldIfPresent(SObject recordItem, String objectApiName, String fieldApiName, Object value) {
        if (recordItem == null || value == null || !hasField(objectApiName, fieldApiName)) {
            return;
        }
        recordItem.put(fieldApiName, value);
    }

    private static Boolean hasField(String objectApiName, String fieldApiName) {
        return fieldMapFor(objectApiName).containsKey(fieldApiName);
    }

    private static Map<String, Schema.SObjectField> fieldMapFor(String objectApiName) {
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectApiName);
        if (objectType == null) {
            return new Map<String, Schema.SObjectField>();
        }
        return objectType.getDescribe().fields.getMap();
    }

    private static String firstExisting(Map<String, Schema.SObjectField> fieldMap, List<String> candidates) {
        if (fieldMap == null || candidates == null) {
            return null;
        }
        for (String candidate : candidates) {
            if (fieldMap.containsKey(candidate)) {
                return candidate;
            }
        }
        return null;
    }

    private static Boolean isAllowedPicklistValue(String objectApiName, String fieldApiName, String value) {
        if (String.isBlank(value)) {
            return false;
        }
        Map<String, Schema.SObjectField> fieldMap = fieldMapFor(objectApiName);
        if (!fieldMap.containsKey(fieldApiName)) {
            return false;
        }

        Schema.DescribeFieldResult fieldDescribe = fieldMap.get(fieldApiName).getDescribe();
        if (fieldDescribe.getType() != Schema.DisplayType.Picklist) {
            return true;
        }
        for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
            if (entry.getValue() == value) {
                return true;
            }
        }
        return false;
    }
}