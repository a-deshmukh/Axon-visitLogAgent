public with sharing class VisitDraftUpsertAction {
    public class Request {
        @InvocableVariable(label='Request Id' description='Used only to build the deduplication key for Visit matching when existingVisitId is not provided.')
        public String requestId;
        @InvocableVariable(label='Acting User Id' description='Used as the Visit owner and to upsert a Visitor record tied to the Visit.')
        public String actingUserId;
        @InvocableVariable(label='Channel Type' description='Normalized to a source/channel value for the Visit and Visit Artifact (SalesforceMobile, WhatsApp, SMS), and included in the dedupe key.')
        public String channelType;
        @InvocableVariable(label='External Message Id' description='Used to build the dedupe key and to find or upsert a Visit_Artifact__c record by external message ID.')
        public String externalMessageId;
        @InvocableVariable(label='Work Type Developer Name' description='Resolved into a WorkType record ID and assigned to the Visit’s work type field.')
        public String workTypeDeveloperName;
        @InvocableVariable(label='Existing Visit Id' description='If provided as a valid Id, the class updates that Visit instead of creating a new one; otherwise it may use the dedupe key to find an existing Visit.')
        public String existingVisitId;
        @InvocableVariable(label='Provider Person Account Id' description='Assigned as the Visit account/provider account field and used as fallback participant for the VisitedParty record.')
        public String providerPersonAccountId;
        @InvocableVariable(label='Provider Person Contact Id' description='Used as the primary participant for the VisitedParty record associated with the Visit.')
        public String providerPersonContactId;
        @InvocableVariable(label='Facility Business Account Id' description='Assigned to the Visit’s facility-related account field.')
        public String facilityBusinessAccountId;
        @InvocableVariable(label='Healthcare Facility Id' description='Present on the request contract but not referenced by the current implementation.')
        public String healthcareFacilityId;
        @InvocableVariable(label='Location Id' description='Assigned to the Visit location field.')
        public String locationId;
        @InvocableVariable(label='Visit Start Time' description='Mapped to one of the Visit start date/time fields and used in the dedupe key.') 
        public Datetime visitStartTime;
        @InvocableVariable(label='Visit End Time' description='Mapped to one of the Visit end date/time fields.') 
        public Datetime visitEndTime;
        @InvocableVariable(label='Language Code' description='Written to Visit language and Visit Artifact language fields.')
        public String languageCode;
        @InvocableVariable(label='Raw Input Text' description='Saved into Visit_Artifact__c.Raw_Text__c and affects artifact type logic when no normalized summary exists.')
        public String rawInputText;
        @InvocableVariable(label='Normalized Summary' description='Saved into Visit_Artifact__c.Normalized_Text__c and used to determine artifact type (“Summary” vs “Transcript”).')
        public String normalizedSummary;
        @InvocableVariable(label='Finalize After Save' description='Controls the output statusCode: if true and no missing fields, response becomes ReadyToFinalize; otherwise it can remain DraftSaved.') 
        public Boolean finalizeAfterSave;
    }
    
    public class Response {
        @InvocableVariable(label='Success' description='Indicates whether the draft save/upsert process completed without an exception.') 
        public Boolean success;
        @InvocableVariable(label='Status Code' description='Returns DraftSaved, ReadyToFinalize, NeedsReview, INVALID_INPUT, CONFIG_ERROR, NOT_FOUND, or ERROR.')
        public String statusCode;
        @InvocableVariable(label='User Message' description='User-facing summary of the result or the error message if an exception occurred.')
        public String userMessage;
        @InvocableVariable(label='Visit Id' description='The ID of the created or updated Visit record.')
        public String visitId;
        @InvocableVariable(label='Visitor Id' description='The ID of the related Visitor record created or found for the acting user.')
        public String visitorId;
        @InvocableVariable(label='Visited Party Id' description='The ID of the related VisitedParty record created or found for the provider contact or account.')
        public String visitedPartyId;
        @InvocableVariable(label='Visit Artifact Id' description='The ID of the Visit Artifact record created or updated for this Visit.')
        public String visitArtifactId;
        @InvocableVariable(label='Visit Status' description='Always initialized to Draft for the Visit process in this action.')
        public String visitStatus;
        @InvocableVariable(label='Missing Fields' description='Lists which required request fields are missing or incomplete after save review, such as workTypeDeveloperName, visitStartTime, locationId, providerPersonAccountId, providerPersonContactId, facilityBusinessAccountId, or summaryText.') 
        public List<String> missingFields;
    }
    
    @InvocableMethod(label='Visit Draft Upsert Action' description='Creates or updates a Visit draft, Visitor, Visited Party, and Visit Artifact.')
    public static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request requestItem : requests) {
            responses.add(handleOne(requestItem));
        }
        return responses;
    }
    
    private static Response handleOne(Request requestItem) {
        Response responseItem = new Response();
        responseItem.success = false;
        responseItem.visitStatus = 'Draft';
        responseItem.missingFields = new List<String>();
        
        if (requestItem == null) {
            responseItem.statusCode = 'INVALID_INPUT';
            responseItem.userMessage = 'Request payload is required.';
            return responseItem;
        }
        if (!Schema.getGlobalDescribe().containsKey('Visit')) {
            responseItem.statusCode = 'CONFIG_ERROR';
            responseItem.userMessage = 'Visit object is not available in this org context.';
            return responseItem;
        }
        
        try {
            String dedupeKey = buildDedupeKey(requestItem);
            Id visitId = resolveVisitId(requestItem.existingVisitId, dedupeKey);
            Boolean isCreate = visitId == null;
            
            Visit visitRecord;
            if (isCreate) {
                visitRecord = new Visit();
            } else {
                List<Visit> visits = Database.query(
                    'SELECT Id FROM Visit WHERE Id = \'' +
                    String.escapeSingleQuotes(String.valueOf(visitId)) +
                    '\' LIMIT 1'
                    );
                if (visits.isEmpty()) {
                    responseItem.statusCode = 'NOT_FOUND';
                    responseItem.userMessage = 'Visit not found for the provided existingVisitId.';
                    return responseItem;
                }
                visitRecord = visits[0];
            }
            
            Id actingUserId = toId(requestItem.actingUserId) ?? UserInfo.getUserId();
            applyVisitFields(visitRecord, requestItem, dedupeKey, actingUserId);
            
            upsert visitRecord;
            
            visitId = visitRecord.Id;
            
            //Id visitorId = upsertVisitor(visitId, actingUserId);
            Id visitedPartyId = upsertVisitedParty(
                visitId,
            toId(requestItem.providerPersonContactId)
                );
            //Id visitArtifactId = upsertVisitArtifact(visitId, requestItem);
            
            responseItem.visitId = String.valueOf(visitId);
            //responseItem.visitorId = visitorId == null ? null : String.valueOf(visitorId);
            responseItem.visitedPartyId = visitedPartyId == null ? null : String.valueOf(visitedPartyId);
            //responseItem.visitArtifactId = visitArtifactId == null ? null : String.valueOf(visitArtifactId);
           // responseItem.missingFields = evaluateMissingFields(requestItem, visitedPartyId);
            
            if (responseItem.missingFields.isEmpty()) {
                responseItem.success = true;
                responseItem.statusCode = requestItem.finalizeAfterSave == true ? 'ReadyToFinalize' : 'DraftSaved';
                responseItem.userMessage = isCreate ? 'Visit draft created successfully.' : 'Visit draft updated successfully.';
            } else {
                responseItem.success = true;
                responseItem.statusCode = 'NeedsReview';
                responseItem.userMessage = 'Draft saved with missing fields requiring user confirmation.';
            }
        } catch (Exception ex) {
            responseItem.success = false;
            responseItem.statusCode = 'ERROR';
            responseItem.userMessage = ex.getMessage();
        }
        
        return responseItem;
    }
    
    private static Id resolveVisitId(String existingVisitId, String dedupeKey) {
        Id typedVisitId = toId(existingVisitId);
        if (typedVisitId != null) {
            return typedVisitId;
        }
        if (String.isBlank(dedupeKey) || !hasField('Visit', 'Agent_Dedupe_Key__c')) {
            return null;
        }
        
        List<SObject> existingByDedupe = Database.query(
            'SELECT Id FROM Visit WHERE Agent_Dedupe_Key__c = \'' +
            String.escapeSingleQuotes(dedupeKey) +
            '\' ORDER BY LastModifiedDate DESC LIMIT 1'
            );
        return existingByDedupe.isEmpty() ? null : (Id) existingByDedupe[0].get('Id');
    }
    
    private static void applyVisitFields(Visit visitRecord, Request requestItem, String dedupeKey, Id actingUserId) {
        visitRecord.Agent_Dedupe_Key__c = dedupeKey;
        visitRecord.Agent_Language_Code__c = requestItem.languageCode;
        
        String channelValue = normalizeChannel(requestItem.channelType);
        if (isAllowedPicklistValue('Visit', 'Agent_Entry_Channel__c', channelValue)) {
            visitRecord.Agent_Entry_Channel__c=channelValue;
        }
        
        visitRecord.PlaceId=toId(requestItem.locationId);
        visitRecord.AccountId=toId(requestItem.facilityBusinessAccountId);
        visitRecord.VisitorId=actingUserId;
        visitRecord.OwnerId = actingUserId;
        visitRecord.ActualVisitStartTime = requestItem.visitStartTime;
        visitRecord.PlannedVisitStartTime = requestItem.visitStartTime;
        visitRecord.ActualVisitEndTime = requestItem.visitEndTime;
        visitRecord.VisitTypeId = resolveWorkTypeId(requestItem.workTypeDeveloperName);
    }
    
    private static Id resolveWorkTypeId(String workTypeDeveloperName) {
        if (String.isBlank(workTypeDeveloperName)) {
            return null;
        }
        
        try {
            List<SObject> rows = Database.query(
                'SELECT Id FROM WorkType WHERE Name = \'' +
                String.escapeSingleQuotes(workTypeDeveloperName.trim()) +
                '\' LIMIT 1'
                );
            return rows.isEmpty() ? null : (Id) rows[0].get('Id');
        } catch (Exception ex) {
            return null;
        }
    }
    
    private static Id upsertVisitor(Id visitId, Id actingUserId) {
        if (visitId == null || actingUserId == null || !Schema.getGlobalDescribe().containsKey('Visitor')) {
            return null;
        }
        
        Map<String, Schema.SObjectField> visitorFields = Schema.getGlobalDescribe().get('Visitor').getDescribe().fields.getMap();
        String visitField = firstExisting(visitorFields, new List<String>{ 'VisitId', 'Visit__c' });
        String userField = firstExisting(visitorFields, new List<String>{ 'UserId', 'User__c', 'VisitorUserId' });
        if (visitField == null || userField == null) {
            return null;
        }
        
        List<SObject> existing = Database.query(
            'SELECT Id FROM Visitor WHERE ' +
            visitField +
            ' = \'' +
            String.escapeSingleQuotes(String.valueOf(visitId)) +
            '\' AND ' +
            userField +
            ' = \'' +
            String.escapeSingleQuotes(String.valueOf(actingUserId)) +
            '\' LIMIT 1'
            );
        if (!existing.isEmpty()) {
            return (Id) existing[0].get('Id');
        }
        
        SObject visitor = Schema.getGlobalDescribe().get('Visitor').newSObject();
        visitor.put(visitField, visitId);
        visitor.put(userField, actingUserId);
        insert visitor;
        return (Id) visitor.get('Id');
    }
    
    private static Id upsertVisitedParty(Id visitId, Id providerPersonContactId) {
        

        
        List<SObject> existing = Database.query(
            'SELECT Id FROM VisitedParty WHERE VisitId = \'' +
            String.escapeSingleQuotes(String.valueOf(visitId)) +
            '\' AND ContactId = \'' +
            String.escapeSingleQuotes(String.valueOf(providerPersonContactId)) +
            '\' LIMIT 1'
            );
        if (!existing.isEmpty()) {
            return (Id) existing[0].get('Id');
        }
        
        visitedParty vParty = new VisitedParty();
        vParty.visitId = visitId;
        vParty.ContactId =  providerPersonContactId;
        insert vParty;
        return vParty.Id;
    }
    
    private static Id upsertVisitArtifact(Id visitId, Request requestItem) {
        if (visitId == null || !Schema.getGlobalDescribe().containsKey('Visit_Artifact__c')) {
            return null;
        }
        
        String artifactType = deriveArtifactType(requestItem);
        String sourceChannel = normalizeChannel(requestItem.channelType);
        String externalMessageId = String.isBlank(requestItem.externalMessageId) ? null : requestItem.externalMessageId.trim();
        
        SObject artifact;
        if (!String.isBlank(externalMessageId) && hasField('Visit_Artifact__c', 'External_Message_Id__c')) {
            List<SObject> existing = Database.query(
                'SELECT Id FROM Visit_Artifact__c WHERE Visit__c = \'' +
                String.escapeSingleQuotes(String.valueOf(visitId)) +
                '\' AND External_Message_Id__c = \'' +
                String.escapeSingleQuotes(externalMessageId) +
                '\' ORDER BY LastModifiedDate DESC LIMIT 1'
                );
            artifact = existing.isEmpty() ? null : existing[0];
        }
        
        if (artifact == null) {
            artifact = Schema.getGlobalDescribe().get('Visit_Artifact__c').newSObject();
            artifact.put('Visit__c', visitId);
        }
        
        artifact.put('Artifact_Type__c', artifactType);
        if (isAllowedPicklistValue('Visit_Artifact__c', 'Source_Channel__c', sourceChannel)) {
            setFieldIfPresent(artifact, 'Visit_Artifact__c', 'Source_Channel__c', sourceChannel);
        }
        setFieldIfPresent(artifact, 'Visit_Artifact__c', 'Language_Code__c', requestItem.languageCode);
        setFieldIfPresent(artifact, 'Visit_Artifact__c', 'External_Message_Id__c', externalMessageId);
        setFieldIfPresent(artifact, 'Visit_Artifact__c', 'Raw_Text__c', requestItem.rawInputText);
        setFieldIfPresent(artifact, 'Visit_Artifact__c', 'Normalized_Text__c', requestItem.normalizedSummary);
        
        if (artifact.get('Id') == null) {
            insert artifact;
        } else {
            update artifact;
        }
        return (Id) artifact.get('Id');
    }
    
    private static String deriveArtifactType(Request requestItem) {
        if (!String.isBlank(requestItem.externalMessageId)) {
            return 'Channel Message';
        }
        if (!String.isBlank(requestItem.rawInputText) && String.isBlank(requestItem.normalizedSummary)) {
            return 'Transcript';
        }
        return 'Summary';
    }
    
    private static List<String> evaluateMissingFields(Request requestItem, Id visitedPartyId) {
        List<String> missing = new List<String>();
        if (String.isBlank(requestItem.workTypeDeveloperName)) {
            missing.add('workTypeDeveloperName');
        }
        if (requestItem.visitStartTime == null) {
            missing.add('visitStartTime');
        }
        if (String.isBlank(requestItem.locationId)) {
            missing.add('locationId');
        }
        if (String.isBlank(requestItem.providerPersonAccountId)) {
            missing.add('providerPersonAccountId');
        }
        if (visitedPartyId == null) {
            missing.add('providerPersonContactId');
        }
        if (String.isBlank(requestItem.facilityBusinessAccountId)) {
            missing.add('facilityBusinessAccountId');
        }
        if (String.isBlank(requestItem.normalizedSummary) && String.isBlank(requestItem.rawInputText)) {
            missing.add('summaryText');
        }
        return missing;
    }
    
    private static String buildDedupeKey(Request requestItem) {
        List<String> parts = new List<String>();
        if (!String.isBlank(requestItem.channelType)) {
            parts.add(requestItem.channelType.trim());
        }
        if (!String.isBlank(requestItem.externalMessageId)) {
            parts.add(requestItem.externalMessageId.trim());
        }
        if (!String.isBlank(requestItem.requestId)) {
            parts.add(requestItem.requestId.trim());
        }
        if (!String.isBlank(requestItem.providerPersonAccountId)) {
            parts.add(requestItem.providerPersonAccountId.trim());
        }
        if (requestItem.visitStartTime != null) {
            parts.add(String.valueOf(requestItem.visitStartTime.getTime()));
        }
        
        if (parts.isEmpty()) {
            return null;
        }
        
        String dedupe = String.join(parts, '|');
        if (dedupe.length() > 255) {
            dedupe = dedupe.substring(0, 255);
        }
        return dedupe;
    }
    
    private static String normalizeChannel(String channelType) {
        String normalized = String.isBlank(channelType) ? 'SalesforceMobile' : channelType.trim();
        if (normalized.equalsIgnoreCase('SalesforceMobile')) {
            return 'SalesforceMobile';
        }
        if (normalized.equalsIgnoreCase('WhatsApp')) {
            return 'WhatsApp';
        }
        if (normalized.equalsIgnoreCase('SMS')) {
            return 'SMS';
        }
        return 'SalesforceMobile';
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
        if (recordItem == null || value == null) {
            return;
        }
        recordItem.put(fieldApiName, value);
    }
    
    private static void setFirstExistingField(SObject recordItem, String objectApiName, List<String> fieldCandidates, Object value) {
        if (recordItem == null || value == null) {
            return;
        }
        Map<String, Schema.SObjectField> fieldMap = fieldMapFor(objectApiName);
        String fieldApiName = firstExisting(fieldMap, fieldCandidates);
        if (fieldApiName != null) {
            recordItem.put(fieldApiName, value);
        }
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