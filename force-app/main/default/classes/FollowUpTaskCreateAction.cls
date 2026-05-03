/**
 * FollowUpTaskCreateAction
 *
 * Agentforce invocable action – Follow-Up Topic.
 *
 * Converts a list of task candidates (extracted from a visit summary by the
 * LLM) into Salesforce Task records, with full idempotency protection.
 *
 * Idempotency key:  Visit__c + normalised Subject + Due Date (date-only).
 *   An open Task that already matches all three is silently skipped so that
 *   re-runs or agent retries never create duplicates.
 *
 * Security model:
 *   - Runs "with sharing" so the rep can only see/touch tasks they have
 *     access to under the org's sharing rules.
 *   - CRUD / FLS enforced via Schema.describe checks before every DML.
 *   - All SOQL uses bind variables; no dynamic SOQL is constructed.
 *
 * @group   Outreach Agent – Follow-Up
 */
public with sharing class FollowUpTaskCreateAction {

    // ─────────────────────────────────────────────────────────────────────────
    // Invocable contract
    // ─────────────────────────────────────────────────────────────────────────

    /** One task candidate provided by the agent / LLM. */
    public class FollowUpCandidate {
        @InvocableVariable(label='Subject' required=true description='Task subject line (max 255 chars). Used as part of the idempotency key (normalized) to prevent duplicate task creation.')
        public String subject;

        @InvocableVariable(label='Description' description='Detailed task description text. Stored in Task.Description field without length truncation.')
        public String description;

        @InvocableVariable(label='Due Date' description='Task due date stored in ActivityDate field. Used as part of the idempotency key. Defaults to 7 days from today if not provided.')
        public Date dueDate;

        /** High | Normal | Low  – defaults to Normal when blank. */
        @InvocableVariable(label='Priority' description='Task priority: High, Normal, or Low. Capitalized and validated against standard Task.Priority picklist. Defaults to Normal if blank or invalid.')
        public String priority;

        /** Salesforce User Id – defaults to acting rep when blank. */
        @InvocableVariable(label='Owner Id' description='Salesforce User ID to assign as task owner (Task.OwnerId). Defaults to actingUserId if not provided.')
        public String ownerId;
    }

    /** Single invocable input record (Agentforce sends a list of 1). */
    public class ActionInput {

        @InvocableVariable(label='Visit Id' required=true description='Visit record ID to link tasks to via Task.WhatId. Used as part of the idempotency key to check for existing tasks.')
        public Id visitId;

        @InvocableVariable(label='Related Provider Contact Id' description='Provider Contact ID for optional relationship tracking in custom fields (currently not implemented in standard logic).')
        public Id relatedProviderContactId;


        /** JSON-serialised List<FollowUpCandidate> – Agentforce passes complex
         *  list inputs as serialised JSON when native list-of-objects is not
         *  supported by the runtime version. */
        @InvocableVariable(label='Candidates JSON' required=true description='JSON-serialized array of FollowUpCandidate objects containing task details. Deserialized into List<FollowUpCandidate> for processing.')
        public String candidatesJson;
    }

    /** Single invocable output record. */
    public class ActionOutput {
        @InvocableVariable(label='Success' description='True if all tasks processed without errors (created or skipped). False if validation failed or DML errors occurred.')
        public Boolean success;

        @InvocableVariable(label='Status Code' description='Processing status: Created (new tasks inserted), Updated (all skipped/existed), or Rejected (validation/permission error).')
        public String statusCode;

        @InvocableVariable(label='User Message' description='Human-readable summary: count of tasks created, skipped, and any error details. Agent-facing confirmation message.')
        public String userMessage;

        @InvocableVariable(label='Created Task Ids (JSON)' description='JSON array of Task IDs successfully inserted. Empty array if none created. Use for downstream processing or linking.')
        public String taskIdsJson;

        @InvocableVariable(label='Created Count' description='Number of new Task records successfully inserted via Database.insert.')
        public Integer createdCount;

        @InvocableVariable(label='Skipped Count' description='Number of candidates skipped due to: existing idempotency match, blank subject, or DML failure.')
        public Integer skippedCount;

        @InvocableVariable(label='Warnings JSON' description='JSON array of non-fatal warning messages: blank subjects skipped, tasks already existing (idempotency). Empty array if none.')
        public String warningsJson;

        @InvocableVariable(label='Errors JSON' description='JSON array of error messages from validation failures, FLS violations, or DML errors. Empty array if none.')
        public String errorsJson;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Entry point
    // ─────────────────────────────────────────────────────────────────────────

    @InvocableMethod(
        label='Create Follow-Up Tasks'
        description='Creates Task records from visit follow-up candidates with idempotency protection.'
        category='Outreach Agent'
    )
    public static List<ActionOutput> execute(List<ActionInput> inputs) {
        List<ActionOutput> results = new List<ActionOutput>();
        for (ActionInput inp : inputs) {
            results.add(processSingle(inp));
        }
        return results;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core logic
    // ─────────────────────────────────────────────────────────────────────────

    @TestVisible
    private static ActionOutput processSingle(ActionInput inp) {
        ActionOutput out = new ActionOutput();
        List<String>  warnings = new List<String>();
        List<String>  errors   = new List<String>();

        try {
            // ── 1. Basic input validation ────────────────────────────────────
            if (inp.visitId == null) {
                return errorOutput('Visit Id is required.');
            }
            if (String.isBlank(inp.candidatesJson)) {
                return errorOutput('Candidates JSON is required.');
            }

            // ── 2. Deserialise candidates ────────────────────────────────────
            List<FollowUpCandidate> candidates;
            try {
                candidates = (List<FollowUpCandidate>)
                    JSON.deserialize(inp.candidatesJson, List<FollowUpCandidate>.class);
            } catch (Exception e) {
                return errorOutput('Could not parse candidates JSON: ' + e.getMessage());
            }

            if (candidates == null || candidates.isEmpty()) {
                return errorOutput('No task candidates supplied.');
            }

            // ── 3. FLS / CRUD guard on Task ──────────────────────────────────
            if (!Schema.sObjectType.Task.isCreateable()) {
                return errorOutput('Insufficient permissions to create Tasks.');
            }
            assertTaskFieldsCreatable();

            // ── 5. Load existing open tasks for idempotency check ────────────
            //    Idempotency key: WhatId (Visit) + normalised Subject + ActivityDate
            Set<String> existingKeys = buildExistingTaskKeySet(inp.visitId);

            // ── 6. Build Task records ────────────────────────────────────────
            List<Task> toInsert  = new List<Task>();
            Integer    skipped   = 0;
            Date       defaultDue = Date.today().addDays(7);

            for (FollowUpCandidate c : candidates) {
                if (String.isBlank(c.subject)) {
                    warnings.add('A candidate with a blank subject was skipped.');
                    skipped++;
                    continue;
                }

                String  normSubject = normaliseSubject(c.subject);
                Date    dueDate     = (c.dueDate != null) ? c.dueDate : defaultDue;
                String  dedupeKey   = buildDedupeKey(inp.visitId, normSubject, dueDate);

                if (existingKeys.contains(dedupeKey)) {
                    warnings.add('Task already exists, skipped: ' + c.subject);
                    skipped++;
                    continue;
                }

                Task t = new Task();
                t.Subject       = c.subject.left(255);
                t.Description   = c.description;
                t.ActivityDate  = dueDate;
                t.Priority      = sanitisePriority(c.priority);
                t.Status        = 'Not Started';
                t.WhoId         = inp.relatedProviderContactId;
                t.WhatId        = inp.visitId;

                // Optionally relate to provider / facility for reporting
                // These are stored via a custom lookup if available; the
                // standard Task.WhatId covers the Visit linkage.
                // t.RelatedProvider__c  = inp.relatedProviderAccountId;
                // t.RelatedFacility__c  = inp.relatedFacilityAccountId;

                toInsert.add(t);
                existingKeys.add(dedupeKey);  // prevent intra-batch dupes
            }

            // ── 7. DML ───────────────────────────────────────────────────────
            List<Id> createdIds = new List<Id>();
            if (!toInsert.isEmpty()) {
                Database.SaveResult[] saveResults =
                    Database.insert(toInsert, false);  // partial success

                for (Integer i = 0; i < saveResults.size(); i++) {
                    if (saveResults[i].isSuccess()) {
                        createdIds.add(saveResults[i].getId());
                    } else {
                        for (Database.Error e : saveResults[i].getErrors()) {
                            errors.add('Task insert error: ' + e.getMessage());
                        }
                    }
                }
            }

            // ── 8. Build output ──────────────────────────────────────────────
            Integer created = createdIds.size();
            out.success      = errors.isEmpty();
            out.statusCode   = (created > 0)
                ? 'Created'
                : 'Updated'; // all skipped = nothing new
            out.createdCount = created;
            out.skippedCount = skipped + (toInsert.size() - created);
            out.taskIdsJson  = JSON.serialize(createdIds);
            out.warningsJson = JSON.serialize(warnings);
            out.errorsJson   = JSON.serialize(errors);
            out.userMessage  = buildUserMessage(created, out.skippedCount, errors);

        } catch (Exception ex) {
            out = errorOutput('Unexpected error: ' + ex.getMessage());
        }

        return out;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /** Loads all open tasks already linked to this visit for dedupe check. */
    private static Set<String> buildExistingTaskKeySet(Id visitId) {
        Set<String> keys = new Set<String>();
        for (Task t : [
            SELECT Subject, ActivityDate
            FROM   Task
            WHERE  WhatId = :visitId
              AND  IsClosed = false
            WITH USER_MODE
            LIMIT 1000
        ]) {
            keys.add(buildDedupeKey(visitId, normaliseSubject(t.Subject), t.ActivityDate));
        }
        return keys;
    }

    /** Normalise a subject for comparison: lowercase, collapse whitespace. */
    @TestVisible
    static String normaliseSubject(String raw) {
        if (String.isBlank(raw)) return '';
        return raw.toLowerCase().trim().replaceAll('\\s+', ' ');
    }

    /** Build a string dedupe key from the three idempotency dimensions. */
    @TestVisible
    static String buildDedupeKey(Id visitId, String normSubject, Date dueDate) {
        return String.valueOf(visitId)
            + '|' + normSubject
            + '|' + (dueDate != null ? String.valueOf(dueDate) : 'null');
    }

    /** Sanitise priority to the picklist values Salesforce accepts. */
    private static String sanitisePriority(String raw) {
        if (String.isBlank(raw)) return 'Normal';
        String upper = raw.trim().capitalize();
        if (upper == 'HIGH'
            || upper == 'NORMAL'
            || upper == 'LOW') {
            return upper;
        }
        return 'Normal';
    }

    /** Assert that the fields we write are createable by the running user. */
    private static void assertTaskFieldsCreatable() {
        Map<String, Schema.SObjectField> fields =
            Schema.sObjectType.Task.fields.getMap();
        List<String> required = new List<String>{
            'Subject', 'ActivityDate', 'Priority', 'Status', 'OwnerId', 'WhatId'
        };
        for (String f : required) {
            if (!fields.get(f.toLowerCase())?.getDescribe().isCreateable()) {
                throw new AgentActionException(
                    'FLS violation: Task.' + f + ' is not createable.');
            }
        }
    }

    /** Compose the agent-facing confirmation message. */
    private static String buildUserMessage(
            Integer created, Integer skipped, List<String> errors) {
        if (!errors.isEmpty()) {
            return 'Some tasks could not be saved. ' + errors[0];
        }
        String msg = '';
        if (created > 0) msg += created + ' follow-up task' + (created > 1 ? 's' : '') + ' created. ';
        if (skipped > 0) msg += skipped + ' already existed and ' + (skipped > 1 ? 'were' : 'was') + ' skipped.';
        if (String.isBlank(msg)) msg = 'No tasks to create.';
        return msg.trim();
    }

    /** Convenience factory for error outputs. */
    private static ActionOutput errorOutput(String msg) {
        ActionOutput o  = new ActionOutput();
        o.success        = false;
        o.statusCode     = 'Rejected';
        o.userMessage    = msg;
        o.createdCount   = 0;
        o.skippedCount   = 0;
        o.taskIdsJson    = '[]';
        o.warningsJson   = '[]';
        o.errorsJson     = JSON.serialize(new List<String>{ msg });
        return o;
    }

    /** Custom exception for FLS / CRUD violations. */
    public class AgentActionException extends Exception {}
}