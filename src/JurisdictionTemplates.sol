// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Jurisdiction Templates for Insolvency Governance
/// @notice Implements real-world insolvency law thresholds from different jurisdictions
/// @dev These templates define voting thresholds, timeframes, and governance rules

enum Jurisdiction {
    US_CHAPTER_11,          // United States - Chapter 11 Reorganization
    US_CHAPTER_7,           // United States - Chapter 7 Liquidation
    UK_CVA,                 // United Kingdom - Company Voluntary Arrangement
    UK_ADMINISTRATION,      // United Kingdom - Administration
    GERMANY_INSOLVENCY,     // Germany - Traditional Insolvency (InsO)
    GERMANY_STARUG,         // Germany - Preventive Restructuring (StaRUG)
    SINGAPORE_IRDA,         // Singapore - Insolvency, Restructuring and Dissolution Act
    CAYMAN_LIQUIDATION,     // Cayman Islands - Common for crypto funds
    DEFI_STANDARD           // DeFi-native (balanced approach)
}

/// @notice Core governance thresholds for insolvency proceedings
struct VotingThresholds {
    uint16 approvalThresholdBps;      // % by value to approve settlement (basis points)
    uint16 approvalHeadcountBps;      // % by number of holders (0 = not required)
    uint16 vetoThresholdBps;          // % by value to block/veto settlement
    uint16 vetoQuorumBps;             // Minimum participation for valid veto
    bool requiresDualTest;             // Must pass BOTH value AND headcount tests
}

/// @notice Timeframes for insolvency proceedings (in seconds)
struct InsolvencyTimeframes {
    uint32 redemptionBreachPeriod;    // How long before breach triggers insolvency
    uint32 settlementPeriod;          // Time for fund manager to propose settlement
    uint32 votingPeriod;              // Time for creditors to vote on settlement
    uint32 extensionPeriod;           // Extension if good faith deposit posted
    uint32 challengePeriod;           // Post-execution challenge window
}

/// @notice Rules and flags for insolvency proceedings
struct InsolvencyRules {
    bool absolutePriorityRule;        // Senior must be paid in full before junior
    bool parPassuOption;              // Allow equal distribution option
    bool transferLockOnTrigger;       // Lock transfers when insolvency triggered
    uint16 interestRateBps;           // Legal interest rate on claims (annual, bps)
}

/// @notice Full governance parameters for insolvency proceedings
struct JurisdictionParams {
    string name;
    string description;
    VotingThresholds voting;
    InsolvencyTimeframes timeframes;
    InsolvencyRules rules;
}

library JurisdictionTemplates {

    /// @notice Get jurisdiction parameters
    /// @param j The jurisdiction type
    /// @return params The governance parameters for that jurisdiction
    function get(Jurisdiction j) internal pure returns (JurisdictionParams memory params) {

        // ═══════════════════════════════════════════════════════════════════
        // UNITED STATES - CHAPTER 11 (Reorganization)
        // ═══════════════════════════════════════════════════════════════════
        // Source: 11 U.S.C. § 1126 - Acceptance of plan
        // - 2/3 (66.67%) by value AND >1/2 (50%) by number per class
        // - Cramdown available if fair and equitable
        // ═══════════════════════════════════════════════════════════════════
        if (j == Jurisdiction.US_CHAPTER_11) {
            return JurisdictionParams({
                name: "US Chapter 11",
                description: "United States Bankruptcy Code - Chapter 11 Reorganization",
                voting: VotingThresholds({
                    approvalThresholdBps: 6667,     // 66.67% by value
                    approvalHeadcountBps: 5001,     // >50% by number
                    vetoThresholdBps: 3334,         // 33.34% blocking minority
                    vetoQuorumBps: 500,             // 5% minimum participation
                    requiresDualTest: true
                }),
                timeframes: InsolvencyTimeframes({
                    redemptionBreachPeriod: 7 days,
                    settlementPeriod: 30 days,
                    votingPeriod: 25 days,          // Typical ballot deadline
                    extensionPeriod: 15 days,
                    challengePeriod: 14 days
                }),
                rules: InsolvencyRules({
                    absolutePriorityRule: true,
                    parPassuOption: false,
                    transferLockOnTrigger: true,
                    interestRateBps: 500            // ~5% federal judgment rate
                })
            });
        }

        // ═══════════════════════════════════════════════════════════════════
        // UNITED STATES - CHAPTER 7 (Liquidation)
        // ═══════════════════════════════════════════════════════════════════
        // Source: 11 U.S.C. § 726 - Distribution of property
        // - No creditor vote on liquidation (trustee distributes)
        // - Strict absolute priority rule
        // ═══════════════════════════════════════════════════════════════════
        if (j == Jurisdiction.US_CHAPTER_7) {
            return JurisdictionParams({
                name: "US Chapter 7",
                description: "United States Bankruptcy Code - Chapter 7 Liquidation",
                voting: VotingThresholds({
                    approvalThresholdBps: 0,        // No vote needed for liquidation
                    approvalHeadcountBps: 0,
                    vetoThresholdBps: 0,            // No veto in liquidation
                    vetoQuorumBps: 0,
                    requiresDualTest: false
                }),
                timeframes: InsolvencyTimeframes({
                    redemptionBreachPeriod: 7 days,
                    settlementPeriod: 0,            // Direct to liquidation
                    votingPeriod: 0,
                    extensionPeriod: 0,
                    challengePeriod: 7 days
                }),
                rules: InsolvencyRules({
                    absolutePriorityRule: true,     // Strict priority
                    parPassuOption: false,
                    transferLockOnTrigger: true,
                    interestRateBps: 500
                })
            });
        }

        // ═══════════════════════════════════════════════════════════════════
        // UNITED KINGDOM - CVA (Company Voluntary Arrangement)
        // ═══════════════════════════════════════════════════════════════════
        // Source: Insolvency Act 1986, Part I
        // - 75% by value of unsecured creditors who vote
        // - Secondary: 50% excluding connected parties
        // ═══════════════════════════════════════════════════════════════════
        if (j == Jurisdiction.UK_CVA) {
            return JurisdictionParams({
                name: "UK CVA",
                description: "United Kingdom - Company Voluntary Arrangement",
                voting: VotingThresholds({
                    approvalThresholdBps: 7500,     // 75% by value
                    approvalHeadcountBps: 5001,     // 50%+ excluding connected parties
                    vetoThresholdBps: 2500,         // 25% can block
                    vetoQuorumBps: 500,
                    requiresDualTest: true
                }),
                timeframes: InsolvencyTimeframes({
                    redemptionBreachPeriod: 7 days,
                    settlementPeriod: 28 days,      // UK uses 28-day periods
                    votingPeriod: 28 days,
                    extensionPeriod: 14 days,
                    challengePeriod: 28 days        // 28-day challenge window
                }),
                rules: InsolvencyRules({
                    absolutePriorityRule: false,    // CVA can modify priority
                    parPassuOption: true,
                    transferLockOnTrigger: true,
                    interestRateBps: 800            // ~8% UK judgment rate
                })
            });
        }

        // ═══════════════════════════════════════════════════════════════════
        // UNITED KINGDOM - ADMINISTRATION
        // ═══════════════════════════════════════════════════════════════════
        // Source: Insolvency Act 1986, Schedule B1
        // - Administrator appointed, creditors' committee advises
        // - Distribution follows statutory priority
        // ═══════════════════════════════════════════════════════════════════
        if (j == Jurisdiction.UK_ADMINISTRATION) {
            return JurisdictionParams({
                name: "UK Administration",
                description: "United Kingdom - Administration Procedure",
                voting: VotingThresholds({
                    approvalThresholdBps: 5001,     // Simple majority for key decisions
                    approvalHeadcountBps: 0,        // Value only
                    vetoThresholdBps: 1000,         // 10% can requisition meeting
                    vetoQuorumBps: 1000,
                    requiresDualTest: false
                }),
                timeframes: InsolvencyTimeframes({
                    redemptionBreachPeriod: 7 days,
                    settlementPeriod: 14 days,
                    votingPeriod: 14 days,
                    extensionPeriod: 14 days,
                    challengePeriod: 28 days
                }),
                rules: InsolvencyRules({
                    absolutePriorityRule: true,
                    parPassuOption: false,
                    transferLockOnTrigger: true,
                    interestRateBps: 800
                })
            });
        }

        // ═══════════════════════════════════════════════════════════════════
        // GERMANY - TRADITIONAL INSOLVENCY (InsO)
        // ═══════════════════════════════════════════════════════════════════
        // Source: Insolvenzordnung (InsO)
        // - >50% by value AND >50% by number in each class
        // ═══════════════════════════════════════════════════════════════════
        if (j == Jurisdiction.GERMANY_INSOLVENCY) {
            return JurisdictionParams({
                name: "Germany InsO",
                description: "Germany - Traditional Insolvency Proceedings",
                voting: VotingThresholds({
                    approvalThresholdBps: 5001,     // >50% by value
                    approvalHeadcountBps: 5001,     // >50% by number
                    vetoThresholdBps: 5000,         // 50% blocking
                    vetoQuorumBps: 500,
                    requiresDualTest: true
                }),
                timeframes: InsolvencyTimeframes({
                    redemptionBreachPeriod: 7 days,
                    settlementPeriod: 21 days,      // 3-week reporting period
                    votingPeriod: 21 days,
                    extensionPeriod: 14 days,
                    challengePeriod: 14 days
                }),
                rules: InsolvencyRules({
                    absolutePriorityRule: true,
                    parPassuOption: false,
                    transferLockOnTrigger: true,
                    interestRateBps: 500            // German legal rate
                })
            });
        }

        // ═══════════════════════════════════════════════════════════════════
        // GERMANY - StaRUG (Preventive Restructuring)
        // ═══════════════════════════════════════════════════════════════════
        // Source: Unternehmensstabilisierungs- und -restrukturierungsgesetz
        // - 75% by value in each class
        // - Cross-class cramdown available
        // ═══════════════════════════════════════════════════════════════════
        if (j == Jurisdiction.GERMANY_STARUG) {
            return JurisdictionParams({
                name: "Germany StaRUG",
                description: "Germany - Preventive Restructuring Framework",
                voting: VotingThresholds({
                    approvalThresholdBps: 7500,     // 75% by value
                    approvalHeadcountBps: 0,        // No headcount requirement
                    vetoThresholdBps: 2500,         // 25% blocking
                    vetoQuorumBps: 500,
                    requiresDualTest: false
                }),
                timeframes: InsolvencyTimeframes({
                    redemptionBreachPeriod: 7 days,
                    settlementPeriod: 21 days,
                    votingPeriod: 21 days,
                    extensionPeriod: 14 days,
                    challengePeriod: 14 days
                }),
                rules: InsolvencyRules({
                    absolutePriorityRule: true,     // Required for cramdown
                    parPassuOption: false,
                    transferLockOnTrigger: true,
                    interestRateBps: 500
                })
            });
        }

        // ═══════════════════════════════════════════════════════════════════
        // SINGAPORE - IRDA
        // ═══════════════════════════════════════════════════════════════════
        // Source: Insolvency, Restructuring and Dissolution Act 2018
        // - 75% by value AND majority (>50%) by number
        // - Super priority for rescue financing
        // ═══════════════════════════════════════════════════════════════════
        if (j == Jurisdiction.SINGAPORE_IRDA) {
            return JurisdictionParams({
                name: "Singapore IRDA",
                description: "Singapore - Insolvency, Restructuring and Dissolution Act",
                voting: VotingThresholds({
                    approvalThresholdBps: 7500,     // 75% by value
                    approvalHeadcountBps: 5001,     // >50% by number
                    vetoThresholdBps: 2500,
                    vetoQuorumBps: 500,
                    requiresDualTest: true
                }),
                timeframes: InsolvencyTimeframes({
                    redemptionBreachPeriod: 7 days,
                    settlementPeriod: 30 days,
                    votingPeriod: 30 days,
                    extensionPeriod: 30 days,       // Singapore allows longer extensions
                    challengePeriod: 14 days
                }),
                rules: InsolvencyRules({
                    absolutePriorityRule: true,
                    parPassuOption: false,
                    transferLockOnTrigger: true,
                    interestRateBps: 535            // Singapore default rate 5.35%
                })
            });
        }

        // ═══════════════════════════════════════════════════════════════════
        // CAYMAN ISLANDS - LIQUIDATION
        // ═══════════════════════════════════════════════════════════════════
        // Source: Companies Act (2023 Revision)
        // - Simple majority by value for ordinary resolutions
        // - 75% for special resolutions
        // - Common jurisdiction for crypto funds
        // ═══════════════════════════════════════════════════════════════════
        if (j == Jurisdiction.CAYMAN_LIQUIDATION) {
            return JurisdictionParams({
                name: "Cayman Liquidation",
                description: "Cayman Islands - Official Liquidation",
                voting: VotingThresholds({
                    approvalThresholdBps: 7500,     // 75% for special resolution
                    approvalHeadcountBps: 0,
                    vetoThresholdBps: 2500,
                    vetoQuorumBps: 500,
                    requiresDualTest: false
                }),
                timeframes: InsolvencyTimeframes({
                    redemptionBreachPeriod: 7 days,
                    settlementPeriod: 21 days,
                    votingPeriod: 21 days,
                    extensionPeriod: 14 days,
                    challengePeriod: 21 days
                }),
                rules: InsolvencyRules({
                    absolutePriorityRule: true,
                    parPassuOption: true,           // Pari passu common in Cayman
                    transferLockOnTrigger: true,
                    interestRateBps: 500
                })
            });
        }

        // ═══════════════════════════════════════════════════════════════════
        // DEFI STANDARD (Balanced Approach)
        // ═══════════════════════════════════════════════════════════════════
        // A balanced approach drawing from best practices across jurisdictions
        // - Dual test like US/Singapore for fairness
        // - Faster timeframes for crypto speed
        // - Strong creditor protections
        // ═══════════════════════════════════════════════════════════════════
        if (j == Jurisdiction.DEFI_STANDARD) {
            return JurisdictionParams({
                name: "DeFi Standard",
                description: "DeFi-native balanced insolvency framework",
                voting: VotingThresholds({
                    approvalThresholdBps: 6667,     // 66.67% by value (US standard)
                    approvalHeadcountBps: 5001,     // >50% by number
                    vetoThresholdBps: 3334,         // 33.34% blocking
                    vetoQuorumBps: 500,             // 5% quorum
                    requiresDualTest: true
                }),
                timeframes: InsolvencyTimeframes({
                    redemptionBreachPeriod: 7 days,
                    settlementPeriod: 30 days,
                    votingPeriod: 14 days,          // Faster for DeFi
                    extensionPeriod: 7 days,
                    challengePeriod: 7 days
                }),
                rules: InsolvencyRules({
                    absolutePriorityRule: true,
                    parPassuOption: true,
                    transferLockOnTrigger: true,
                    interestRateBps: 500
                })
            });
        }

        revert("Unknown jurisdiction");
    }

    /// @notice Get just the name of a jurisdiction
    function getName(Jurisdiction j) internal pure returns (string memory) {
        return get(j).name;
    }

    /// @notice Check if jurisdiction requires dual test (value + headcount)
    function requiresDualTest(Jurisdiction j) internal pure returns (bool) {
        return get(j).voting.requiresDualTest;
    }

    /// @notice Get approval threshold in basis points
    function getApprovalThreshold(Jurisdiction j) internal pure returns (uint16) {
        return get(j).voting.approvalThresholdBps;
    }

    /// @notice Check if jurisdiction uses absolute priority rule
    function usesAbsolutePriority(Jurisdiction j) internal pure returns (bool) {
        return get(j).rules.absolutePriorityRule;
    }

    /// @notice Get voting thresholds
    function getVotingThresholds(Jurisdiction j) internal pure returns (VotingThresholds memory) {
        return get(j).voting;
    }

    /// @notice Get timeframes
    function getTimeframes(Jurisdiction j) internal pure returns (InsolvencyTimeframes memory) {
        return get(j).timeframes;
    }

    /// @notice Get rules
    function getRules(Jurisdiction j) internal pure returns (InsolvencyRules memory) {
        return get(j).rules;
    }
}
