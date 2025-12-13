// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum TemplateType {
    TWO_TRANCHE_DEBT_EQUITY,
    THREE_TRANCHE_SENIOR_MEZZ_EQUITY,
    FOUR_TRANCHE_SECURED_SENIOR_MEZZ_EQUITY,
    PARI_PASSU
}

enum VaultMode {
    WRAPPED_ONLY,
    WHOLE_SUPPLY
}

enum UnclaimedFundsOption {
    REDISTRIBUTE_PRO_RATA,
    DONATE_TO_WATERFALL
}

struct Template {
    string name;
    uint8 trancheCount;
    string[] trancheNames;
}

library Templates {
    function get(TemplateType t) internal pure returns (Template memory) {
        if (t == TemplateType.TWO_TRANCHE_DEBT_EQUITY) {
            string[] memory names = new string[](2);
            names[0] = "Senior";
            names[1] = "Junior";
            return Template("Debt/Equity", 2, names);
        }

        if (t == TemplateType.THREE_TRANCHE_SENIOR_MEZZ_EQUITY) {
            string[] memory names = new string[](3);
            names[0] = "Senior";
            names[1] = "Mezzanine";
            names[2] = "Junior";
            return Template("Senior/Mezz/Equity", 3, names);
        }

        if (t == TemplateType.FOUR_TRANCHE_SECURED_SENIOR_MEZZ_EQUITY) {
            string[] memory names = new string[](4);
            names[0] = "Secured";
            names[1] = "Senior";
            names[2] = "Mezzanine";
            names[3] = "Equity";
            return Template("Full Capital Structure", 4, names);
        }

        if (t == TemplateType.PARI_PASSU) {
            string[] memory names = new string[](1);
            names[0] = "Equal";
            return Template("Pari Passu", 1, names);
        }

        revert("Unknown template");
    }

    function getTrancheCount(TemplateType t) internal pure returns (uint8) {
        if (t == TemplateType.TWO_TRANCHE_DEBT_EQUITY) return 2;
        if (t == TemplateType.THREE_TRANCHE_SENIOR_MEZZ_EQUITY) return 3;
        if (t == TemplateType.FOUR_TRANCHE_SECURED_SENIOR_MEZZ_EQUITY) return 4;
        if (t == TemplateType.PARI_PASSU) return 1;
        revert("Unknown template");
    }
}
