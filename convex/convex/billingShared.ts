export const FREE_BILLS_PER_PERIOD = 4;

type UsageBackedUser = {
	createdAt: number;
	freeBillsUsedInPeriod?: number;
	currentPeriodStartAt?: number;
	currentPeriodEndAt?: number;
	billCreditsBalance?: number;
};

export type BillingUsageState = {
	freeBillsUsedInPeriod: number;
	currentPeriodStartAt: number;
	currentPeriodEndAt: number;
	billCreditsBalance: number;
};

export function deriveBillingUsageState(
	user: UsageBackedUser,
	now: number,
): BillingUsageState {
	const { periodStartAt, periodEndAt } = computeCurrentPeriodWindow(
		user.createdAt,
		now,
	);
	const storedFreeUsed = normalizeNonNegativeInt(user.freeBillsUsedInPeriod);
	const inStoredPeriod =
		user.currentPeriodStartAt === periodStartAt &&
		user.currentPeriodEndAt === periodEndAt;

	return {
		freeBillsUsedInPeriod: inStoredPeriod ? storedFreeUsed : 0,
		currentPeriodStartAt: periodStartAt,
		currentPeriodEndAt: periodEndAt,
		billCreditsBalance: normalizeNonNegativeInt(user.billCreditsBalance),
	};
}

export function consumeBillAllowance(
	state: BillingUsageState,
): { updated: BillingUsageState; source: "free" | "credit" | null } {
	if (state.freeBillsUsedInPeriod < FREE_BILLS_PER_PERIOD) {
		return {
			updated: {
				...state,
				freeBillsUsedInPeriod: state.freeBillsUsedInPeriod + 1,
			},
			source: "free",
		};
	}

	if (state.billCreditsBalance > 0) {
		return {
			updated: {
				...state,
				billCreditsBalance: state.billCreditsBalance - 1,
			},
			source: "credit",
		};
	}

	return {
		updated: state,
		source: null,
	};
}

export function usageStateToPatch(state: BillingUsageState) {
	return {
		freeBillsUsedInPeriod: state.freeBillsUsedInPeriod,
		currentPeriodStartAt: state.currentPeriodStartAt,
		currentPeriodEndAt: state.currentPeriodEndAt,
		billCreditsBalance: state.billCreditsBalance,
	};
}

function normalizeNonNegativeInt(value: unknown): number {
	if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
		return 0;
	}
	return Math.floor(value);
}

function computeCurrentPeriodWindow(
	anchorMs: number,
	nowMs: number,
): { periodStartAt: number; periodEndAt: number } {
	if (!Number.isFinite(anchorMs) || anchorMs <= 0) {
		const fallbackStart = nowMs;
		return {
			periodStartAt: fallbackStart,
			periodEndAt: addMonthsClampedUTC(fallbackStart, 1),
		};
	}

	let periodStartAt = anchorMs;
	let periodEndAt = addMonthsClampedUTC(periodStartAt, 1);

	while (periodEndAt <= nowMs) {
		periodStartAt = periodEndAt;
		periodEndAt = addMonthsClampedUTC(periodStartAt, 1);
	}

	return { periodStartAt, periodEndAt };
}

function addMonthsClampedUTC(timestampMs: number, months: number): number {
	const date = new Date(timestampMs);
	const year = date.getUTCFullYear();
	const month = date.getUTCMonth();
	const day = date.getUTCDate();
	const hours = date.getUTCHours();
	const minutes = date.getUTCMinutes();
	const seconds = date.getUTCSeconds();
	const milliseconds = date.getUTCMilliseconds();

	const targetMonthIndex = month + months;
	const targetYear = year + Math.floor(targetMonthIndex / 12);
	const normalizedMonth =
		((targetMonthIndex % 12) + 12) % 12;
	const lastDayOfTargetMonth = new Date(
		Date.UTC(targetYear, normalizedMonth + 1, 0),
	).getUTCDate();
	const clampedDay = Math.min(day, lastDayOfTargetMonth);

	return Date.UTC(
		targetYear,
		normalizedMonth,
		clampedDay,
		hours,
		minutes,
		seconds,
		milliseconds,
	);
}
