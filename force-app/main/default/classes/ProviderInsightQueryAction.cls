public with sharing class ProviderInsightQueryAction {
    private static final Integer DEFAULT_LOOKBACK_DAYS = 90;

    public class Request {
        @InvocableVariable(
            label='Provider Person Account ID'
            description='The Salesforce ID of the provider as a Person Account. Use this when the healthcare provider is stored as a Person Account (individual practitioner account). Provide the 15 or 18 character Salesforce ID.'
        )
        public String providerPersonAccountId;
        
        @InvocableVariable(
            label='Provider Contact ID'
            description='The Salesforce ID of the provider as a Contact record. Use this when the healthcare provider is stored as a Contact related to a facility Account. Provide the 15 or 18 character Salesforce ID.'
        )
        public String providerContactId;
        
        @InvocableVariable(
            label='Facility Business Account ID'
            description='The Salesforce ID of the healthcare facility as a Business Account (hospital, clinic, medical center). Use this when querying about a specific facility location. Provide the 15 or 18 character Salesforce ID.'
        )
        public String facilityBusinessAccountId;
        
        @InvocableVariable(
            label='Lookback Days'
            description='Number of days to look back when analyzing visit history, referrals, and pending tasks. Defaults to 90 days if not specified. Use smaller values (30-60) for recent activity, larger values (180-365) for comprehensive history.'
        )
        public Integer lookbackDays;
        
        @InvocableVariable(
            label='Question Type'
            description='Type of insight query to perform. Valid values: "RelationshipSummary" (default - overall relationship metrics), "LastVisit" (focus on visit history), "LastReferral" (focus on referral activity), "PendingFollowUps" (focus on open tasks). Use this to tailor the narrative response.'
        )
        public String questionType;
    }

    public class Response {
        @InvocableVariable(
            label='Success'
            description='Indicates whether the query executed successfully. True if data was retrieved without errors, false if validation failed or an exception occurred.'
        )
        public Boolean success;
        
        @InvocableVariable(
            label='Status Code'
            description='Status code indicating the result: "SUCCESS" for successful execution, "INVALID_INPUT" for missing required parameters, "ERROR" for execution failures. Use this to determine if the response data is valid.'
        )
        public String statusCode;
        
        @InvocableVariable(
            label='User Message'
            description='Human-readable message describing the outcome of the operation. Contains error details if the operation failed, or confirmation message if successful.'
        )
        public String userMessage;
        
        @InvocableVariable(
            label='Narrative Answer'
            description='A formatted summary of the provider relationship insights based on the questionType requested. Contains key metrics like visit counts, dates, and pending tasks in a conversational format suitable for agent responses.'
        )
        public String narrativeAnswer;
        
        @InvocableVariable(
            label='Last Visit Date'
            description='The date of the most recent visit to this provider or facility within the lookback period. Null if no visits found. Use this to inform the user about recent activity.'
        )
        public Date lastVisitDate;
        
        @InvocableVariable(
            label='Last Referral Date'
            description='The date of the most recent referral to this provider or facility within the lookback period. Null if no referrals found. Use this to track referral activity and follow-up timing.'
        )
        public Date lastReferralDate;
        
        @InvocableVariable(
            label='Visit Count'
            description='Total number of visits to this provider or facility within the lookback period. Use this metric to assess relationship strength and engagement level.'
        )
        public Integer visitCount;
        
        @InvocableVariable(
            label='Pending Task Count'
            description='Total number of open or in-progress tasks related to this provider or facility. Use this to identify outstanding follow-ups and action items.'
        )
        public Integer pendingTaskCount;
        
        @InvocableVariable(
            label='Facility'
            description='The facility Account record with complete details including name, phone, website URL, and full billing address (street, city, state, postal code, country). Use this to provide complete facility contact information to the user.'
        )
        public Account facility;
        
        @InvocableVariable(
            label='Provider'
            description='The provider Contact record with complete details including name, title, phone, email, department, and description/bio. Use this to provide complete provider information and background to the user.'
        )
        public Contact provider;
    }

    @InvocableMethod(label='Provider Insight Query Action' description='Returns concise provider relationship context for the employee agent.')
    public static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request requestItem : requests) {
            responses.add(queryProviderInsight(requestItem));
        }
        return responses;
    }

    private static Response queryProviderInsight(Request request) {
        Response response = new Response();
        response.success = false;
        response.visitCount = 0;
        response.pendingTaskCount = 0;

        if (request == null) {
            response.statusCode = 'INVALID_INPUT';
            response.userMessage = 'Request payload is required.';
            return response;
        }

        Id providerId = toId(request.providerContactId);
        Id facilityId = toId(request.facilityBusinessAccountId);

        if (providerId == null && facilityId == null) {
            response.statusCode = 'INVALID_INPUT';
            response.userMessage = 'At least one of providerContactId or facilityBusinessAccountId is required.';
            return response;
        }

        try {
            Integer lookbackDays = request.lookbackDays != null ? request.lookbackDays : DEFAULT_LOOKBACK_DAYS;
            Datetime windowStart = Datetime.now().addDays(-lookbackDays);

            // Query facility and provider records
            if (facilityId != null) {
                response.facility = queryFacility(facilityId);
            }
            
            Id contactId = toId(request.providerContactId);
            if (contactId != null) {
                response.provider = queryProvider(contactId);
            } else if (providerId != null) {
                response.provider = queryProvider(providerId);
            }

            // Query visits
            InsightData data = new InsightData();
            data.visits = queryVisits(providerId, facilityId, windowStart);
            data.pendingTasks = queryPendingTasks(providerId, facilityId, windowStart);
            data.referrals = queryReferrals(providerId, facilityId, windowStart);

            response.visitCount = data.visits.size();
            response.pendingTaskCount = data.pendingTasks.size();
            response.lastVisitDate = data.visits.isEmpty() ? null : data.visits[0];
            response.lastReferralDate = data.referrals.isEmpty() ? null : data.referrals[0];

            String questionType = String.isBlank(request.questionType) ? 'RelationshipSummary' : request.questionType.trim();
            response.narrativeAnswer = buildNarrativeAnswer(data, questionType);

            response.success = true;
            response.statusCode = 'SUCCESS';
            response.userMessage = 'Provider insight retrieved successfully.';
        } catch (Exception ex) {
            response.success = false;
            response.statusCode = 'ERROR';
            response.userMessage = ex.getMessage();
        }

        return response;
    }

    private static Account queryFacility(Id facilityId) {
        if (facilityId == null) {
            return null;
        }
        
        try {
            List<Account> facilities = [
                SELECT Id, Name, Phone, Website,
                       BillingStreet, BillingCity, BillingState,
                       BillingPostalCode, BillingCountry
                FROM Account
                WHERE Id = :facilityId
                LIMIT 1
            ];
            return facilities.isEmpty() ? null : facilities[0];
        } catch (Exception ex) {
            // Silently handle query errors
            return null;
        }
    }

    private static Contact queryProvider(Id providerId) {
        if (providerId == null) {
            return null;
        }
        
        try {
            List<Contact> providers = [
                SELECT Id, Name, Title, Phone, Email, AccountId,
                       Description, Department
                FROM Contact
                WHERE Id = :providerId
                LIMIT 1
            ];
            return providers.isEmpty() ? null : providers[0];
        } catch (Exception ex) {
            // Silently handle query errors
            return null;
        }
    }

    private static List<Date> queryVisits(Id providerId, Id facilityId, Datetime windowStart) {

        List<Date> visitDates = new List<Date>();
        String whereClause = buildVisitWhereClause(providerId, facilityId, windowStart);

        if (String.isBlank(whereClause)) {
            return visitDates;
        }

        try {
            String soql = 'SELECT Id, CreatedDate FROM VisitedParty WHERE ' + whereClause + ' ORDER BY Visit.ActualVisitStartTime DESC LIMIT 100';
            List<SObject> visits = Database.query(soql);

            for (SObject visit : visits) {
                Datetime created = (Datetime) visit.get('CreatedDate');
                if (created != null) {
                    visitDates.add(created.date());
                }
            }
        } catch (Exception ex) {
            // Silently handle query errors, return what we have
        }

        return visitDates;
    }

    private static String buildVisitWhereClause(Id providerId, Id facilityId, Datetime windowStart) {
        List<String> conditions = new List<String>();

        if (providerId != null) {
            conditions.add('ContactId = \'' + String.escapeSingleQuotes(String.valueOf(providerId)) + '\'');
        }

        if (facilityId != null) {
            conditions.add('visit.AccountId = \'' + String.escapeSingleQuotes(String.valueOf(facilityId)) + '\'');
        }

        if (windowStart != null ) {
            conditions.add('visit.ActualVisitStartTime >=:windowStart');
        }

        return conditions.isEmpty() ? null : '(' + String.join(conditions, ' AND ') + ')';
    }

    private static List<Date> queryPendingTasks(Id providerId, Id facilityId, Datetime windowStart) {

        List<Date> taskDates = new List<Date>();
        String whereClause = buildTaskWhereClause(providerId, facilityId, windowStart);

        if (String.isBlank(whereClause)) {
            return taskDates;
        }

        try {
            String soql = 'SELECT Id, ActivityDate FROM Task WHERE ' + whereClause + ' ORDER BY ActivityDate ASC LIMIT 100';
            List<SObject> tasks = Database.query(soql);

            for (SObject task : tasks) {
                Date activityDate = (Date) task.get('ActivityDate');
                if (activityDate != null) {
                    taskDates.add(activityDate);
                }
            }
        } catch (Exception ex) {
            // Silently handle query errors
        }

        return taskDates;
    }

    private static String buildTaskWhereClause(Id providerId, Id facilityId, Datetime windowStart) {
        List<String> conditions = new List<String>();

        // Pending status condition
        conditions.add('(Status = \'Open\' OR Status = \'In Progress\' OR IsClosed = false)');

        if (providerId != null) {
            conditions.add('WhoId = \'' + String.escapeSingleQuotes(String.valueOf(providerId)) + '\'');
        }

        if (facilityId != null) {
            conditions.add('WhatId = \'' + String.escapeSingleQuotes(String.valueOf(facilityId)) + '\'');
        }

        if (windowStart != null) {
            conditions.add('CreatedDate >= :windowStart');
        }

        return conditions.isEmpty() ? null : '(' + String.join(conditions, ' AND ') + ')';
    }

    private static List<Date> queryReferrals(Id providerId, Id facilityId, Datetime windowStart) {
        if (!Schema.getGlobalDescribe().containsKey('ClinicalServiceRequest')) {
            return new List<Date>();
        }

        List<Date> referralDates = new List<Date>();
        String whereClause = buildReferralWhereClause(providerId, facilityId, windowStart);

        if (String.isBlank(whereClause)) {
            return referralDates;
        }

        try {
            String soql = 'SELECT Id, CreatedDate FROM ClinicalServiceRequest WHERE ' + whereClause + ' ORDER BY CreatedDate DESC LIMIT 50';
            List<SObject> referrals = Database.query(soql);

            for (SObject referral : referrals) {
                Datetime created = (Datetime) referral.get('CreatedDate');
                if (created != null) {
                    referralDates.add(created.date());
                }
            }
        } catch (Exception ex) {
            // Silently handle query errors
        }

        return referralDates;
    }

    private static String buildReferralWhereClause(Id providerId, Id facilityId, Datetime windowStart) {
        List<String> conditions = new List<String>();

        Map<String, Schema.SObjectField> refFields = fieldMapFor('ClinicalServiceRequest');

        // Referral provider field lookup
        String providerField = firstExisting(refFields, new List<String>{ 'ReferredToProviderId', 'ReferralRecipient', 'ProviderId' });
        if (providerId != null && providerField != null) {
            conditions.add(providerField + ' = \'' + String.escapeSingleQuotes(String.valueOf(providerId)) + '\'');
        }

        String facilityField = firstExisting(refFields, new List<String>{ 'ReferredToFacilityId', 'FacilityId' });
        if (facilityId != null && facilityField != null) {
            conditions.add(facilityField + ' = \'' + String.escapeSingleQuotes(String.valueOf(facilityId)) + '\'');
        }

        String dateField = firstExisting(refFields, new List<String>{ 'CreatedDate', 'ReferralDate' });
        if (windowStart != null && dateField != null) {
            conditions.add(dateField + ' >=:windowStart');
        }

        return conditions.isEmpty() ? null : '(' + String.join(conditions, ' OR ') + ')';
    }

    private static String buildNarrativeAnswer(InsightData data, String questionType) {
        List<String> keyPoints = new List<String>();

        if (questionType == 'LastVisit') {
            Date lastVisit = data.visits.isEmpty() ? null : data.visits[0];
            if (lastVisit != null) {
                keyPoints.add('Last visit: ' + lastVisit.format());
            }
            keyPoints.add('Total visits: ' + String.valueOf(data.visits.size()));
        } else if (questionType == 'LastReferral') {
            Date lastReferral = data.referrals.isEmpty() ? null : data.referrals[0];
            if (lastReferral != null) {
                keyPoints.add('Last referral: ' + lastReferral.format());
            }
            keyPoints.add('Total referrals: ' + String.valueOf(data.referrals.size()));
        } else if (questionType == 'PendingFollowUps') {
            if (data.pendingTasks.isEmpty()) {
                keyPoints.add('No pending follow-ups.');
            } else {
                keyPoints.add('Pending tasks: ' + String.valueOf(data.pendingTasks.size()));
                if (!data.pendingTasks.isEmpty()) {
                    keyPoints.add('Next due: ' + data.pendingTasks[0].format());
                }
            }
        } else {
            // RelationshipSummary (default)
            keyPoints.add('Visits: ' + String.valueOf(data.visits.size()));
            if (!data.visits.isEmpty()) {
                keyPoints.add('Last visit: ' + data.visits[0].format());
            }
            if (!data.referrals.isEmpty()) {
                keyPoints.add('Last referral: ' + data.referrals[0].format());
            }
            if (data.pendingTasks.size() > 0) {
                keyPoints.add('Pending: ' + String.valueOf(data.pendingTasks.size()));
            }
        }

        return String.join(keyPoints, ' • ');
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

    private class InsightData {
        List<Date> visits;
        List<Date> pendingTasks;
        List<Date> referrals;
    }
}