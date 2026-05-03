import { LightningElement, api } from 'lwc';

export default class ExpenseTypeIcon extends LightningElement {
    @api typeName;

    get normalizedType() {
        return (this.typeName || '').toLowerCase();
    }

    get isTransportation() {
        return this.normalizedType.includes('transportation');
    }

    get isAccommodation() {
        return this.normalizedType.includes('accommodation');
    }

    get isMeals() {
        return this.normalizedType.includes('meals');
    }

    get isIncidental() {
        return this.normalizedType.includes('incidental');
    }

    get label() {
        return this.typeName || 'Expense';
    }

    get containerClass() {
        if (this.isTransportation) {
            return 'icon-wrap transportation';
        }
        if (this.isAccommodation) {
            return 'icon-wrap accommodation';
        }
        if (this.isMeals) {
            return 'icon-wrap meals';
        }
        if (this.isIncidental) {
            return 'icon-wrap incidental';
        }
        return 'icon-wrap other';
    }
}