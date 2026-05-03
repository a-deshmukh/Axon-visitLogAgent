import { LightningElement, api } from 'lwc';
import getVisits from '@salesforce/apex/VisitRelatedListController.getVisits';

const PAGE_SIZE = 5;
const DEFAULT_SORT = 'CreatedDate|DESC';

export default class ContactVisitList extends LightningElement {
    _recordId;
    _objectApiName;
    visits = [];
    hasMore = false;
    sortValue = DEFAULT_SORT;
    isLoading = false;
    isLoadingMore = false;
    errorMessage;
    connected = false;
    reloadQueued = false;

    sortOptions = [
        { label: 'Newest created', value: 'CreatedDate|DESC' },
        { label: 'Oldest created', value: 'CreatedDate|ASC' },
        { label: 'Latest start', value: 'ActualVisitStartTime|DESC' },
        { label: 'Earliest start', value: 'ActualVisitStartTime|ASC' },
        { label: 'Visit type A-Z', value: 'VisitType.Name|ASC' },
        { label: 'Visitor A-Z', value: 'Visitor.Name|ASC' },
        { label: 'Facility A-Z', value: 'Account.Name|ASC' },
        { label: 'Status A-Z', value: 'Status|ASC' }
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

    get hasVisits() {
        return this.visits.length > 0;
    }

    get hasError() {
        return Boolean(this.errorMessage);
    }

    get isInitialLoading() {
        return this.isLoading && !this.isLoadingMore;
    }

    get recordCountLabel() {
        const count = this.visits.length;
        if (count === 0) {
            return 'Recent related visits';
        }
        return this.hasMore ? `${count}+ shown` : `${count} shown`;
    }

    get loadMoreLabel() {
        return this.isLoadingMore ? 'Loading...' : 'Load more';
    }

    handleSortChange(event) {
        this.sortValue = event.detail.value;
        this.loadVisits(true);
    }

    handleLoadMore() {
        this.loadVisits(false);
    }

    queueReload() {
        if (!this.connected || !this._recordId || this.reloadQueued) {
            return;
        }

        this.reloadQueued = true;
        Promise.resolve().then(() => {
            this.reloadQueued = false;
            this.loadVisits(true);
        });
    }

    async loadVisits(reset) {
        if (!this._recordId || this.isLoading) {
            return;
        }

        const [sortField, sortDirection] = this.sortValue.split('|');
        this.errorMessage = undefined;
        this.isLoading = true;
        this.isLoadingMore = !reset;

        try {
            const result = await getVisits({
                recordId: this._recordId,
                objectApiName: this._objectApiName,
                pageSize: PAGE_SIZE,
                offsetSize: reset ? 0 : this.visits.length,
                sortField,
                sortDirection
            });

            const nextRecords = (result?.records || []).map((visit) => this.normalizeVisit(visit));
            this.visits = reset ? nextRecords : [...this.visits, ...nextRecords];
            this.hasMore = Boolean(result?.hasMore);
        } catch (error) {
            this.errorMessage = this.reduceError(error);
            if (reset) {
                this.visits = [];
                this.hasMore = false;
            }
        } finally {
            this.isLoading = false;
            this.isLoadingMore = false;
        }
    }

    normalizeVisit(visit) {
        const visitTypeName = visit.visitTypeName || 'Visit';
        const visitorDisplayName = visit.visitorName || 'Unknown visitor';
        const facilityDisplayName = visit.accountName || 'Facility not recorded';

        return {
            ...visit,
            facilityDisplayName,
            title: visitTypeName,
            visitTypeName,
            visitorDisplayName
        };
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((item) => item.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unable to load visits.';
    }
}