CREATE OR REPLACE PACKAGE PKG_FINANCE_OPS AS

  -- Types
  SUBTYPE t_currency IS VARCHAR2(9);
  SUBTYPE t_component IS VARCHAR2(20);

  -- General error type
  e_invalid_arg EXCEPTION;

  -- Open a finance contract and generate schedules (Murabaha, Mudaraba, Istisna, Ijara)
  PROCEDURE open_contract(
    p_contract_no        IN  VARCHAR2,
    p_customer_id        IN  NUMBER,
    p_prdct_code         IN  VARCHAR2,
    p_fin_product_type   IN  VARCHAR2,
    p_principal_amt      IN  NUMBER,
    p_currency_code      IN  t_currency,
    p_start_date         IN  DATE,
    p_tenor              IN  NUMBER,
    p_tenor_unit         IN  VARCHAR2, -- DAYS/MONTHS/YEARS
    p_frequency          IN  NUMBER,
    p_settlement_acct_id IN  NUMBER,
    p_user_id            IN  VARCHAR2,
    o_contract_id        OUT NUMBER
  );

  -- Accrual up to a date (monthly, quarterly, etc per product settings)
  PROCEDURE accrue_profit(
    p_contract_id IN NUMBER,
    p_as_of_date  IN DATE,
    p_user_id     IN VARCHAR2
  );

  -- Pay an installment component-wise (on-time)
  PROCEDURE pay_installment(
    p_contract_id    IN NUMBER,
    p_installment_no IN NUMBER,
    p_amount         IN NUMBER,
    p_component      IN t_component, -- PRINCIPAL/PROFIT/TAKAFUL/PENALTY
    p_source_acct_id IN NUMBER,
    p_user_id        IN VARCHAR2
  );

  -- Pay overdue installment (includes penalty accumulation per rules)
  PROCEDURE pay_overdue(
    p_contract_id    IN NUMBER,
    p_installment_no IN NUMBER,
    p_amount         IN NUMBER,
    p_source_acct_id IN NUMBER,
    p_user_id        IN VARCHAR2
  );

  -- Prepayment (partial)
  PROCEDURE prepay_partial(
    p_contract_id IN NUMBER,
    p_prepay_amt  IN NUMBER,
    p_value_date  IN DATE,
    p_user_id     IN VARCHAR2
  );

  -- Move overdue to defaulted after configured days
  PROCEDURE mark_default_if_due(
    p_contract_id IN NUMBER,
    p_as_of_date  IN DATE,
    p_user_id     IN VARCHAR2
  );

  -- Foreclosure (full early settlement) with compensation/rebate handling
  PROCEDURE foreclose_contract(
    p_contract_id IN NUMBER,
    p_value_date  IN DATE,
    p_user_id     IN VARCHAR2
  );

  -- Amendments: maturity, principal, profit rate
  PROCEDURE amend_contract(
    p_contract_id IN NUMBER,
    p_effective_date IN DATE,
    p_new_maturity_date IN DATE DEFAULT NULL,
    p_principal_delta   IN NUMBER DEFAULT NULL,
    p_new_profit_rate   IN NUMBER DEFAULT NULL,
    p_user_id           IN VARCHAR2
  );

  -- Reschedule
  PROCEDURE reschedule_contract(
    p_contract_id IN NUMBER,
    p_new_tenor   IN NUMBER,
    p_new_freq    IN NUMBER,
    p_user_id     IN VARCHAR2
  );

  -- Close after last installment paid
  PROCEDURE close_if_fully_paid(
    p_contract_id IN NUMBER,
    p_user_id     IN VARCHAR2
  );

  -- Renew contract per product rules
  PROCEDURE renew_contract(
    p_contract_id IN NUMBER,
    p_renewal_amount IN NUMBER DEFAULT NULL,
    p_user_id     IN VARCHAR2
  );

  -- Financial utilities
  FUNCTION calc_emi_equal_payments(
    p_principal   IN NUMBER,
    p_rate_annual IN NUMBER,
    p_n_periods   IN NUMBER,
    p_freq_per_year IN NUMBER
  ) RETURN NUMBER;

  FUNCTION day_count(
    p_start IN DATE,
    p_end   IN DATE,
    p_basis IN VARCHAR2 -- 'ACT/360','ACT/365'
  ) RETURN NUMBER;

  FUNCTION calc_profit_declining_balance(
    p_outstanding IN NUMBER,
    p_rate_annual IN NUMBER,
    p_days        IN NUMBER,
    p_base_days   IN NUMBER
  ) RETURN NUMBER;

  -- GL helper to write an entry
  PROCEDURE post_gl(
    p_contract_id    IN NUMBER,
    p_installment_id IN NUMBER,
    p_dr_acct        IN VARCHAR2,
    p_cr_acct        IN VARCHAR2,
    p_amount         IN NUMBER,
    p_currency_code  IN VARCHAR2,
    p_event_type     IN VARCHAR2,
    p_ref_no         IN VARCHAR2,
    p_narration      IN VARCHAR2
  );

END PKG_FINANCE_OPS;
/ 
