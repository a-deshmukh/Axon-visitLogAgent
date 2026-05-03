import { LightningElement, api } from 'lwc';
import getExpenses from '@salesforce/apex/ExpenseRelatedListController.getExpenses';
import CURRENCY from '@salesforce/i18n/currency';

const PAGE_SIZE = 5;
const DEFAULT_SORT = 'CreatedDate|DESC';

export default class RelatedExpenseList extends LightningElement {
    _recordId;
    _objectApiName;
    expenses = [];
    hasMore = false;
    sortValue = DEFAULT_SORT;
    isLoading = false;
    isLoadingMore = false;
    errorMessage;
    connected = false;
    reloadQueued = false;
    currencyCode = CURRENCY;

    sortOptions = [
        { label: 'Newest created', value: 'CreatedDate|DESC' },
        { label: 'Oldest created', value: 'CreatedDate|ASC' },
        { label: 'Newest transaction', value: 'TransactionDate|DESC' },
        { label: 'Oldest transaction', value: 'TransactionDate|ASC' },
        { label: 'Highest amount', value: 'Amount|DESC' },
        { label: 'Lowest amount', value: 'Amount|ASC' },
        { label: 'Expense type A-Z', value: 'ExpenseType|ASC' },
        { label: 'Title A-Z', value: 'Title|ASC' },
        { label: 'Facility A-Z', value: 'Account.Name|ASC' },
        { label: 'Contact A-Z', value: 'Contact__r.Name|ASC' }
    ];

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;
        this.queueReload();
    }

    @api
    get objectApiName() {
        return this._objectApiName;
    }

    set objectApiName(value) {
        this._objectApiName = value;
        this.queueReload();
    }

    connectedCallback() {
        this.connected = true;
        this.queueReload();
    }

    get hasExpenses() {
        return this.expenses.length > 0;
    }

    get hasError() {
        return Boolean(this.errorMessage);
    }

    get isInitialLoading() {
        return this.isLoading && !this.isLoadingMore;
    }

    get recordCountLabel() {
        const count = this.expenses.length;
        if (count === 0) {
            return 'Recent related expenses';
        }
        return this.hasMore ? `${count}+ shown` : `${count} shown`;
    }

    get loadMoreLabel() {
        return this.isLoadingMore ? 'Loading...' : 'Load more';
    }

    handleSortChange(event) {
        this.sortValue = event.detail.value;
        this.loadExpenses(true);
    }

    handleLoadMore() {
        this.loadExpenses(false);
    }

    queueReload() {
        if (!this.connected || !this._recordId || this.reloadQueued) {
            return;
        }

        this.reloadQueued = true;
        Promise.resolve().then(() => {
            this.reloadQueued = false;
            this.loadExpenses(true);
        });
    }

    async loadExpenses(reset) {
        if (!this._recordId || this.isLoading) {
            return;
        }

        const [sortField, sortDirection] = this.sortValue.split('|');
        this.errorMessage = undefined;
        this.isLoading = true;
        this.isLoadingMore = !reset;

        try {
            const result = await getExpenses({
                recordId: this._recordId,
                objectApiName: this._objectApiName,
                pageSize: PAGE_SIZE,
                offsetSize: reset ? 0 : this.expenses.length,
                sortField,
                sortDirection
            });

            const nextRecords = (result?.records || []).map((expense) => this.normalizeExpense(expense));
            this.expenses = reset ? nextRecords : [...this.expenses, ...nextRecords];
            this.hasMore = Boolean(result?.hasMore);
        } catch (error) {
            this.errorMessage = this.reduceError(error);
            if (reset) {
                this.expenses = [];
                this.hasMore = false;
            }
        } finally {
            this.isLoading = false;
            this.isLoadingMore = false;
        }
    }

    normalizeExpense(expense) {
        const expenseTypeDisplay = expense.expenseType || 'Other';
        return {
            ...expense,
            expenseTypeDisplay,
            titleDisplay: expense.title || expenseTypeDisplay,
            visitDisplayName: expense.visitName || expense.visitIdText || 'Visit'
        };
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((item) => item.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unable to load expenses.';
    }
}