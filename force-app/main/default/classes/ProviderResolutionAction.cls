public with sharing class ProviderResolutionAction {
    public class Request {
        @InvocableVariable(label='Provider Name' description='Provider name to search for using fuzzy matching against person Account records. Used when exact provider ID is not provided.')
        public String providerName;
        
        @InvocableVariable(label='Facility Name' description='Facility name to search for using fuzzy matching against business Account records. Used when exact facility ID is not provided.')
        public String facilityName;
        
        @InvocableVariable(label='Location Name' description='Location of the facility name to search for using fuzzy matching against Location records.')
        public String locationName;
        
        @InvocableVariable(label='City' description='City name to filter facility search results by BillingCity field. Optional refinement for facility matching.')
        public String city;
        
        @InvocableVariable(label='Current Provider Contact ID' description='Exact provider contact ID for direct lookup. If provided, skips fuzzy name matching and uses exact ID match.')
        public String currentProviderContactId;
        
        @InvocableVariable(label='Current Facility Account ID' description='Exact facility business Account ID for direct lookup. If provided, skips fuzzy name matching and uses exact ID match.')
        public String currentFacilityAccountId;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True if provider and/or facility was resolved (full or partial match). False for errors or no matches found.')
        public Boolean success;
        
        @InvocableVariable(label='Status Code' description='Resolution status: RESOLVED (both matched), NEEDS_REVIEW (partial match), NOT_FOUND (no matches), ERROR (exception occurred), INVALID_INPUT (null request).')
        public String statusCode;
        
        @InvocableVariable(label='User Message' description='Human-readable message describing the resolution outcome and any next steps needed.')
        public String userMessage;
        
        @InvocableVariable(label='Provider Contact ID' description='PersonContactId from the resolved provider person Account. Null if provider not found.')
        public String providerContactId;
        
        @InvocableVariable(label='Facility Business Account ID' description='Resolved business Account ID for the matched facility. Null if facility not found.')
        public String facilityBusinessAccountId;
        
        @InvocableVariable(label='Healthcare Facility ID' description='ID of the HealthcareFacility record linked to the resolved facility Account. Null if not found or object unavailable.')
        public String healthcareFacilityId;
        
        @InvocableVariable(label='Healthcare Practitioner Facility ID' description='ID of the junction HealthcarePractitionerFacility record linking the provider to the facility. Null if either is missing or object unavailable.')
        public String healthcarePractitionerFacilityId;
        
        @InvocableVariable(label='Location ID' description='ID of the Location record associated with the resolved facility Account. Null if not found or object unavailable.')
        public String locationId;
        
        @InvocableVariable(label='Confidence Score' description='Match confidence score: 1.0 (exact IDs provided), 0.95 (both fuzzy matched), 0.65 (partial match), 0 (no matches).')
        public Decimal confidenceScore;
        
        @InvocableVariable(label='Display Summary' description='Human-readable summary showing resolved provider name, facility name, and confidence score formatted for display.')
        public String displaySummary;
    }

    @InvocableMethod(label='Provider Resolution Action' description='Matches provider and facility context using the Health Cloud provider data model.')
    public static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request requestItem : requests) {
            responses.add(resolveOne(requestItem));
        }
        return responses;
    }

    private static Response resolveOne(Request requestItem) {
        Response responseItem = new Response();
        responseItem.success = false;
        responseItem.confidenceScore = 0;

        if (requestItem == null) {
            responseItem.statusCode = 'INVALID_INPUT';
            responseItem.userMessage = 'Request is required.';
            return responseItem;
        }

        try {
            Contact providerContact;
            Account facilityAccount;

            Id providedProviderId = toId(requestItem.currentProviderContactId);
            Id providedFacilityId = toId(requestItem.currentFacilityAccountId);

            if (providedProviderId != null) {
                List<Contact> exactProviders = [
                    SELECT Id, Name
                    FROM Contact
                    WHERE Id = :providedProviderId
                    LIMIT 1
                ];
                if (!exactProviders.isEmpty() && exactProviders[0].IsPersonAccount) {
                    providerContact = exactProviders[0];
                }
            }

            if (providedFacilityId != null) {
                List<Account> exactFacilities = [
                    SELECT Id, Name, BillingCity, IsPersonAccount
                    FROM Account
                    WHERE Id = :providedFacilityId
                    LIMIT 1
                ];
                if (!exactFacilities.isEmpty() && !exactFacilities[0].IsPersonAccount) {
                    facilityAccount = exactFacilities[0];
                }
            }

            if (providerContact == null && !String.isBlank(requestItem.providerName)) {
                String providerLike = asLikeToken(requestItem.providerName);
                List<Contact> providerMatches = [
                    SELECT Id, Name, Description
                    FROM Contact
                    WHERE Name LIKE :providerLike
                    ORDER BY Name
                    LIMIT 5
                ];
                providerContact = (Contact)pickBestByName(providerMatches, requestItem.providerName, null);
            }

            if (facilityAccount == null && !String.isBlank(requestItem.facilityName)) {
                String facilityLike = asLikeToken(requestItem.facilityName);
                String city = String.isBlank(requestItem.city) ? null : requestItem.city.trim();

                List<Account> facilityMatches;
                if (city == null) {
                    facilityMatches = [
                        SELECT Id, Name, BillingCity, IsPersonAccount
                        FROM Account
                        WHERE IsPersonAccount = false
                        AND Name LIKE :facilityLike
                        ORDER BY Name
                        LIMIT 5
                    ];
                } else {
                    String cityLike = asLikeToken(city);
                    facilityMatches = [
                        SELECT Id, Name, BillingCity, IsPersonAccount
                        FROM Account
                        WHERE IsPersonAccount = false
                        AND Name LIKE :facilityLike
                        AND BillingCity LIKE :cityLike
                        ORDER BY Name
                        LIMIT 5
                    ];
                }
                facilityAccount = (Account)pickBestByName(facilityMatches, requestItem.facilityName, null);
            }

            responseItem.providerContactId = providerContact?.Id;
            responseItem.facilityBusinessAccountId = facilityAccount?.Id;

            Id healthcareProviderId = tryResolveHealthcareProviderId(providerContact, facilityAccount);
            responseItem.healthcareFacilityId = tryResolveHealthcareFacilityId(facilityAccount);
            responseItem.healthcarePractitionerFacilityId = tryResolveHealthcarePractitionerFacilityId(
                healthcareProviderId,
                responseItem.healthcareFacilityId
            );
            responseItem.locationId = tryResolveLocationId(facilityAccount, requestItem.locationName);

            Boolean providerResolved = providerContact != null;
            Boolean facilityResolved = facilityAccount != null;
            responseItem.confidenceScore = computeConfidence(requestItem, providerResolved, facilityResolved);
            responseItem.displaySummary = buildSummary(providerContact, facilityAccount, responseItem.confidenceScore);

            if (providerResolved && facilityResolved) {
                responseItem.success = true;
                responseItem.statusCode = 'RESOLVED';
                responseItem.userMessage = 'Provider and facility matched.';
            } else if (providerResolved || facilityResolved) {
                responseItem.success = true;
                responseItem.statusCode = 'NEEDS_REVIEW';
                responseItem.userMessage = 'Partial match found. Confirm missing provider/facility details.';
            } else {
                responseItem.statusCode = 'NOT_FOUND';
                responseItem.userMessage = 'No provider or facility match was found. Please provide more detail.';
            }
        } catch (Exception ex) {
            responseItem.success = false;
            responseItem.statusCode = 'ERROR';
            responseItem.userMessage = ex.getMessage();
        }

        return responseItem;
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

    private static String asLikeToken(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String token = value.trim().replace('%', '').replace('_', '');
        return '%' + token + '%';
    }

    private static sObject pickBestByName(List<sObject> records, String requestedName, String fieldName) {
        if (records == null || records.isEmpty()) {
            return null;
        }
        if (String.isBlank(requestedName)) {
            return records[0];
        }
		fieldName = fieldName??'Name';
        String normalizedRequested = requestedName.trim().toLowerCase();
        for (sObject item : records) {
            if (((String)item?.get(fieldName))?.trim().toLowerCase() == normalizedRequested) {
                return item;
            }
        }
        return records[0];
    }

    private static Decimal computeConfidence(Request requestItem, Boolean providerResolved, Boolean facilityResolved) {
        if (providerResolved && facilityResolved) {
            if (!String.isBlank(requestItem.currentProviderContactId) && !String.isBlank(requestItem.currentFacilityAccountId)) {
                return 1;
            }
            return 0.95;
        }
        if (providerResolved || facilityResolved) {
            return 0.65;
        }
        return 0;
    }

    private static String buildSummary(Contact providerContact, Account facilityAccount, Decimal confidence) {
        List<String> parts = new List<String>();
        if (providerContact != null) {
            parts.add('Provider: ' + providerContact.Name);
        }
        if (facilityAccount != null) {
            parts.add('Facility: ' + facilityAccount.Name);
        }
        parts.add('Confidence: ' + String.valueOf(confidence));
        return String.join(parts, ' | ');
    }

    private static String tryResolveHealthcareProviderId(Contact providerContact, Account facilityAccount) {
        Id contactId = providerContact?.Id;
        Id accountId = facilityAccount?.Id;
        if (contactId == null && accountId == null) {
            return null;
        }

        String soql =
            'SELECT Id FROM HealthcareProvider WHERE (PractitionerId =:contactId OR AccountId =:accountId) AND IsActive = true';
        try {
            List<SObject> rows = Database.query(soql);
            return rows.isEmpty() ? null : String.valueOf(rows[0].get('Id'));
        } catch (Exception ex) {
            return null;
        }
    }

    private static String tryResolveHealthcareFacilityId(Account facilityAccount) {
        if (facilityAccount == null) {
            return null;
        }

        String soql =
            'SELECT Id FROM HealthcareFacility WHERE AccountId = \'' +
            String.escapeSingleQuotes(String.valueOf(facilityAccount.Id)) +
            '\' LIMIT 1';
        try {
            List<SObject> rows = Database.query(soql);
            return rows.isEmpty() ? null : String.valueOf(rows[0].get('Id'));
        } catch (Exception ex) {
            return null;
        }
    }

    private static String tryResolveHealthcarePractitionerFacilityId(String healthcareProviderId, String healthcareFacilityId) {
        if (String.isBlank(healthcareProviderId) || String.isBlank(healthcareFacilityId)) {
            return null;
        }

        String soql =
            'SELECT Id FROM HealthcarePractitionerFacility WHERE HealthcareProviderId = \'' +
            String.escapeSingleQuotes(healthcareProviderId) +
            '\' AND HealthcareFacilityId = \'' +
            String.escapeSingleQuotes(healthcareFacilityId) +
            '\' LIMIT 1';
        try {
            List<SObject> rows = Database.query(soql);
            return rows.isEmpty() ? null : String.valueOf(rows[0].get('Id'));
        } catch (Exception ex) {
            return null;
        }
    }

    private static String tryResolveLocationId(Account facilityAccount, String locationName) {
        if (facilityAccount == null) {
            return null;
        }

        String soql = 'SELECT Id, ParentId, Street  FROM Address WHERE Parent.AccountId = \'' +
            String.escapeSingleQuotes(String.valueOf(facilityAccount.Id)) +
            '\'';
        if (locationName != null) {
            String locationLike = asLikeToken(locationName);
            soql += ' AND Street like \'' +locationLike+ '\'';
                
        }
        soql += 'LIMIT 5';

        try {
            List<sObject> rows = Database.query(soql);
            sObject row = pickBestByName(rows,locationName,'Street');
            return (Id)row?.get('Id');
        } catch (Exception ex) {
            return null;
        }
    }

}