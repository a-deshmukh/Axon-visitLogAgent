import { LightningElement, api } from 'lwc';

export default class VisitTypeIcon extends LightningElement {
    @api typeName;

    get normalizedType() {
        return (this.typeName || '').toLowerCase();
    }

    get isPhysicianOutreach() {
        return this.normalizedType.includes('physician outreach');
    }

    get isReferralFollowUp() {
        return this.normalizedType.includes('referral follow-up');
    }

    get isEventPromotion() {
        return this.normalizedType.includes('event promotion');
    }

    get label() {
        return this.typeName || 'Visit';
    }

    get containerClass() {
        if (this.isPhysicianOutreach) {
            return 'icon-wrap physician';
        }
        if (this.isReferralFollowUp) {
            return 'icon-wrap referral';
        }
        if (this.isEventPromotion) {
            return 'icon-wrap event';
        }
        return 'icon-wrap default';
    }
}