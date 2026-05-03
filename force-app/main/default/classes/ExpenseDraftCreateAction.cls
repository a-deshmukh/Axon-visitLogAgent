public with sharing class ExpenseDraftCreateAction {
    
    // Inner class for expense wrapper input
    public class ExpenseWrapper {
        @InvocableVariable(label='Expense Type' description='The type/category of the expense' )
        public String ExpenseType;
        
        @InvocableVariable(label='Amount' description='The unit price/amount of the expense' )
        public Decimal amount;
        
        @InvocableVariable(label='Quantity' description='The quantity of items/units for this expense' )
        public Integer quantity;
        
        @InvocableVariable(label='Description' description='Detailed description of the expense')
        public String description;
        
        @InvocableVariable(label='Transaction Date' description='The date when the expense transaction occurred' )
        public Date transactionDate;
        
        @InvocableVariable(label='Title' description='Short title or name for the expense' )
        public String title;
    }
    
    // Inner class for error details
    public class ErrorDetail {
        @InvocableVariable(label='Expense Title' description='The title of the expense that failed')
        public String ExpenseTitle;
        
        @InvocableVariable(label='Error Message' description='The error message describing why the expense failed')
        public String ErrorMessage;
    }
    
    // Request structure for invocable method
    public class Request {
        @InvocableVariable(label='Visit ID' description='The ID of the associated Visit record')
        public Id VisitId;
        
        @InvocableVariable(label='Provider Contact ID' description='The ID of the provider Contact record')
        public Id ProviderContactId;
        
        @InvocableVariable(label='Facility Account ID' description='The ID of the facility Account record')
        public Id FacilityAccountId;
        
        @InvocableVariable(label='Expenses' description='List of expense items to create')
        public List<ExpenseWrapper> Expenses;
    }
    
    // Response structure for invocable method
    public class Response {
        @InvocableVariable(label='Success Records' description='List of successfully created Expense records')
        public List<Expense> SuccessRecords;
        
        @InvocableVariable(label='Failed Count' description='Number of expense records that failed to create')
        public Integer FailedCount;
        
        @InvocableVariable(label='User Message' description='User-friendly summary message of the operation result')
        public String UserMessage;
        
        @InvocableVariable(label='Error Details' description='List of error details for failed expense records')
        public List<ErrorDetail> ErrorDetails;
    }
    
    @InvocableMethod(
        label='Create Expenses from Visit' 
        description='Creates multiple expense records from a visit with bulk processing and error handling.'
    )
    public static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();
        
        for (Request req : requests) {
            responses.add(processExpenses(req));
        }
        
        return responses;
    }
    
    /**
     * Process expenses for a single request
     * @param req The request containing visit, contact, account, and expense data
     * @return Response containing success/failure counts, user message, and error details
     */
    private static Response processExpenses(Request req) {
        Response res = new Response();
        res.SuccessRecords = new List<Expense>();
        res.FailedCount = 0;
        res.ErrorDetails = new List<ErrorDetail>();
        
        // Validate input
        String validationError = validateRequest(req);
        if (validationError != null) {
            res.UserMessage = validationError;
            res.FailedCount = req.Expenses != null ? req.Expenses.size() : 0;
            
            // Add all expenses to error details with validation error
            if (req.Expenses != null) {
                for (ExpenseWrapper wrapper : req.Expenses) {
                    String title = getExpenseTitle(wrapper);
                    res.ErrorDetails.add(createErrorDetail(title, validationError));
                }
            }
            return res;
        }
        
        // Build expense records and track wrappers for error mapping
        List<Expense> expensesToInsert = new List<Expense>();
        List<ExpenseWrapper> validWrappers = new List<ExpenseWrapper>();
        
        for (ExpenseWrapper wrapper : req.Expenses) {
            String wrapperValidation = validateExpenseWrapper(wrapper);
            if (wrapperValidation == null) {
                expensesToInsert.add(buildExpenseRecord(wrapper, req));
                validWrappers.add(wrapper);
            } else {
                res.FailedCount++;
                String title = getExpenseTitle(wrapper);
                res.ErrorDetails.add(createErrorDetail(title, wrapperValidation));
            }
        }
        
        // Insert records with partial success handling
        if (!expensesToInsert.isEmpty()) {
            Database.SaveResult[] results = Database.insert(expensesToInsert, false);
            
            // Process results
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    res.SuccessRecords.add(expensesToInsert[i]);
                } else {
                    res.FailedCount++;
                    String title = getExpenseTitle(validWrappers[i]);
                    String errorMessage = getDatabaseErrorMessage(results[i].getErrors());
                    res.ErrorDetails.add(createErrorDetail(title, errorMessage));
                    logErrors(results[i].getErrors());
                }
            }
        }
        
        // Build user message
        res.UserMessage = buildUserMessage(
            res.SuccessRecords.size(), 
            res.FailedCount, 
            req.Expenses.size()
        );
        
        return res;
    }
    
    /**
     * Validate the request object
     * @param req The request to validate
     * @return Error message if validation fails, null otherwise
     */
    private static String validateRequest(Request req) {
        if (req == null) {
            return 'Request cannot be null.';
        }
        
        if (req.ProviderContactId == null) {
            return 'Provider Contact ID is required.';
        }
        
        if (req.FacilityAccountId == null) {
            return 'Facility Account ID is required.';
        }
        
        if (req.Expenses == null || req.Expenses.isEmpty()) {
            return 'At least one expense is required.';
        }
        
        return null;
    }
    
    /**
     * Validate individual expense wrapper
     * @param wrapper The expense wrapper to validate
     * @return Error message if validation fails, null otherwise
     */
    private static String validateExpenseWrapper(ExpenseWrapper wrapper) {
        if (wrapper == null) {
            return 'Expense data cannot be null.';
        }
        
        // Validate required fields
        if (String.isBlank(wrapper.Title)) {
            return 'Title is required.';
        }
        
        if (String.isBlank(wrapper.ExpenseType)) {
            return 'Expense Type is required.';
        }
        
        if (wrapper.Amount == null) {
            return 'Amount is required.';
        }
        
        if (wrapper.Amount <= 0) {
            return 'Amount must be greater than zero.';
        }
        
        if (wrapper.Quantity == null) {
            return 'Quantity is required.';
        }
        
        if (wrapper.Quantity <= 0) {
            return 'Quantity must be greater than zero.';
        }
        
        if (wrapper.TransactionDate == null) {
            return 'Transaction Date is required.';
        }
        
        return null;
    }
    
    /**
     * Get a title identifier for an expense wrapper
     * @param wrapper The expense wrapper
     * @return The title or a placeholder if not available
     */
    private static String getExpenseTitle(ExpenseWrapper wrapper) {
        if (wrapper != null && String.isNotBlank(wrapper.Title)) {
            return wrapper.Title;
        }
        return 'Untitled Expense';
    }
    
    /**
     * Create an ErrorDetail object
     * @param title The expense title
     * @param errorMessage The error message
     * @return ErrorDetail instance
     */
    private static ErrorDetail createErrorDetail(String title, String errorMessage) {
        ErrorDetail detail = new ErrorDetail();
        detail.ExpenseTitle = title;
        detail.ErrorMessage = errorMessage;
        return detail;
    }
    
    /**
     * Extract error messages from database errors
     * @param errors List of database errors
     * @return Combined error message string
     */
    private static String getDatabaseErrorMessage(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'Unknown database error occurred.';
        }
        
        List<String> errorMessages = new List<String>();
        for (Database.Error err : errors) {
            errorMessages.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        
        return String.join(errorMessages, '; ');
    }
    
    /**
     * Build an Expense record from wrapper and request data
     * @param wrapper The expense wrapper containing expense details
     * @param req The request containing visit, contact, and account IDs
     * @return Constructed Expense record
     */
    private static Expense buildExpenseRecord(ExpenseWrapper wrapper, Request req) {
        Expense exp = new Expense();
        
        // Map fields according to specifications
        exp.Visit__c = req.VisitId;
        exp.AccountId = req.FacilityAccountId;
        exp.Contact__c = req.ProviderContactId;
        exp.ExpenseType = wrapper.ExpenseType;
        exp.TransactionDate = wrapper.TransactionDate;
        exp.UnitPrice = wrapper.Amount;
        exp.Title = wrapper.Title;
        exp.Description = wrapper.Description;
        exp.Quantity = wrapper.Quantity;
        exp.Amount = wrapper.Amount * wrapper.Quantity;
        
        return exp;
    }
    
    /**
     * Build user-friendly message based on results
     * @param successCount Number of successfully created expenses
     * @param failedCount Number of failed expense creations
     * @param totalCount Total number of expenses attempted
     * @return User-friendly message
     */
    private static String buildUserMessage(Integer successCount, Integer failedCount, Integer totalCount) {
        if (failedCount == 0) {
            return String.format(
                'Successfully created {0} expense record(s).', 
                new List<Object>{ successCount }
            );
        } else if (successCount == 0) {
            return String.format(
                'Failed to create all {0} expense record(s). Please check the error details.', 
                new List<Object>{ totalCount }
            );
        } else {
            return String.format(
                'Created {0} expense record(s) successfully. {1} record(s) failed. Please review error details.', 
                new List<Object>{ successCount, failedCount }
            );
        }
    }
    
    /**
     * Log database errors for debugging
     * @param errors List of database errors
     */
    private static void logErrors(List<Database.Error> errors) {
        for (Database.Error err : errors) {
            System.debug(LoggingLevel.ERROR, 
                'Expense creation failed: ' + err.getStatusCode() + ' - ' + err.getMessage()
            );
        }
    }
}