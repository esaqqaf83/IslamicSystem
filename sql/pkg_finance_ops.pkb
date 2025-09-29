CREATE OR REPLACE PACKAGE BODY PKG_FINANCE_OPS AS

  PROCEDURE assert_positive(p_val IN NUMBER, p_name IN VARCHAR2) IS
  BEGIN
    IF p_val IS NULL OR p_val <= 0 THEN
      RAISE e_invalid_arg;
    END IF;
  END;

  FUNCTION get_product_rec(p_prdct_code IN VARCHAR2)
    RETURN TAB_PRDCTS_STTNGS%ROWTYPE
  IS
    v_rec TAB_PRDCTS_STTNGS%ROWTYPE;
  BEGIN
    SELECT * INTO v_rec FROM TAB_PRDCTS_STTNGS WHERE PRDCT_CODE = p_prdct_code;
    RETURN v_rec;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20001, 'Product code not found: '||p_prdct_code);
  END;

  FUNCTION get_contract(p_contract_id IN NUMBER)
    RETURN TAB_CONTRACTS%ROWTYPE
  IS
    v_rec TAB_CONTRACTS%ROWTYPE;
  BEGIN
    SELECT * INTO v_rec FROM TAB_CONTRACTS WHERE CONTRACT_ID = p_contract_id FOR UPDATE;
    RETURN v_rec;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20002, 'Contract not found: '||p_contract_id);
  END;

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
  ) IS
  BEGIN
    INSERT INTO TAB_GL_ENTRIES (
      GL_ENTRY_ID, EVENT_DATE, CONTRACT_ID, INSTALLMENT_ID, DR_ACCT, CR_ACCT,
      AMOUNT, CURRENCY_CODE, NARRATION, EVENT_TYPE, REF_NO
    ) VALUES (
      SEQ_GL_ENTRIES.NEXTVAL, SYSDATE, p_contract_id, p_installment_id, p_dr_acct, p_cr_acct,
      p_amount, p_currency_code, p_narration, p_event_type, p_ref_no
    );
  END post_gl;

  FUNCTION day_count(
    p_start IN DATE,
    p_end   IN DATE,
    p_basis IN VARCHAR2
  ) RETURN NUMBER IS
    v_days NUMBER;
  BEGIN
    v_days := p_end - p_start;
    IF p_basis = 'ACT/360' THEN
      RETURN v_days * (360/360);
    ELSIF p_basis = 'ACT/365' THEN
      RETURN v_days * (365/365);
    ELSE
      RETURN v_days; -- fallback
    END IF;
  END;

  FUNCTION calc_profit_declining_balance(
    p_outstanding IN NUMBER,
    p_rate_annual IN NUMBER,
    p_days        IN NUMBER,
    p_base_days   IN NUMBER
  ) RETURN NUMBER IS
  BEGIN
    RETURN ROUND(p_outstanding * (p_rate_annual/100) * (p_days / p_base_days), 3);
  END;

  FUNCTION calc_emi_equal_payments(
    p_principal   IN NUMBER,
    p_rate_annual IN NUMBER,
    p_n_periods   IN NUMBER,
    p_freq_per_year IN NUMBER
  ) RETURN NUMBER IS
    v_r NUMBER;
  BEGIN
    IF p_n_periods <= 0 OR p_principal <= 0 OR p_freq_per_year <= 0 THEN
      RETURN 0;
    END IF;
    v_r := (p_rate_annual/100) / p_freq_per_year;
    IF v_r = 0 THEN
      RETURN ROUND(p_principal / p_n_periods, 3);
    END IF;
    RETURN ROUND(p_principal * v_r / (1 - POWER(1 + v_r, -p_n_periods)), 3);
  END;

  PROCEDURE generate_schedules(
    p_contract_id IN NUMBER,
    p_product     IN TAB_PRDCTS_STTNGS%ROWTYPE
  ) IS
    v_c TAB_CONTRACTS%ROWTYPE;
    v_n NUMBER;
    v_emi NUMBER;
    v_due DATE;
    v_outstanding NUMBER;
    v_base_days NUMBER := NVL(p_product.BASE_DAYS, 360);
  BEGIN
    v_c := get_contract(p_contract_id);
    v_n := v_c.tenor * v_c.freq; -- for MONTHS tenor and monthly freq = 1 -> equals tenor
    IF v_n <= 0 THEN
      RAISE_APPLICATION_ERROR(-20003, 'Invalid tenor/frequency');
    END IF;

    v_outstanding := v_c.principal_amt;
    v_emi := calc_emi_equal_payments(v_outstanding, v_c.profit_rate, v_n, v_c.freq);
    v_due := v_c.start_date;

    FOR i IN 1..v_n LOOP
      -- compute next due date by adding 1 frequency unit in months for simplicity
      v_due := ADD_MONTHS(v_due, 12 / v_c.freq);
      -- profit via declining balance between previous and current due date
      DECLARE
        v_prev DATE := ADD_MONTHS(v_due, -(12 / v_c.freq));
        v_days NUMBER := v_due - v_prev;
        v_profit NUMBER := calc_profit_declining_balance(v_outstanding, v_c.profit_rate, v_days, v_base_days);
        v_principal NUMBER := GREATEST(v_emi - v_profit, 0);
      BEGIN
        INSERT INTO TAB_INSTALLMENTS(
          INSTALLMENT_ID, CONTRACT_ID, INSTL_NO, DUE_DATE,
          PRINCIPAL_DUE, PROFIT_DUE, TOTAL_DUE, STATUS, CREATED_AT
        ) VALUES (
          SEQ_INSTALLMENTS.NEXTVAL, v_c.contract_id, i, v_due,
          v_principal, v_profit, v_principal + v_profit, 'DUE', SYSDATE
        );
        v_outstanding := GREATEST(v_outstanding - v_principal, 0);
      END;
    END LOOP;
  END;

  PROCEDURE open_contract(
    p_contract_no        IN  VARCHAR2,
    p_customer_id        IN  NUMBER,
    p_prdct_code         IN  VARCHAR2,
    p_fin_product_type   IN  VARCHAR2,
    p_principal_amt      IN  NUMBER,
    p_currency_code      IN  VARCHAR2,
    p_start_date         IN  DATE,
    p_tenor              IN  NUMBER,
    p_tenor_unit         IN  VARCHAR2,
    p_frequency          IN  NUMBER,
    p_settlement_acct_id IN  NUMBER,
    p_user_id            IN  VARCHAR2,
    o_contract_id        OUT NUMBER
  ) IS
    v_prod TAB_PRDCTS_STTNGS%ROWTYPE;
    v_contract_id NUMBER;
  BEGIN
    assert_positive(p_principal_amt, 'principal');
    assert_positive(p_tenor, 'tenor');
    assert_positive(p_frequency, 'frequency');

    v_prod := get_product_rec(p_prdct_code);

    INSERT INTO TAB_CONTRACTS(
      CONTRACT_ID, CONTRACT_NO, CUSTOMER_ID, PRDCT_ID, PRINCIPAL_AMT,
      DISBURSED_AMT, CURRENCY_CODE, START_DATE, MATURITY_DATE, TENOR,
      TENOR_UNIT, FREQ, PROFIT_RATE, FIN_PRODUCT_TYPE, FIN_TYPE,
      SETTLEMENT_ACCT_ID, STATUS, CREATED_AT
    ) VALUES (
      SEQ_CONTRACTS.NEXTVAL, p_contract_no, p_customer_id, v_prod.PRDCT_ID, p_principal_amt,
      0, p_currency_code, p_start_date, ADD_MONTHS(p_start_date, p_tenor), p_tenor,
      p_tenor_unit, p_frequency, NVL(v_prod.profit_rate, 0), p_fin_product_type, v_prod.FIN_TYPE,
      p_settlement_acct_id, 'ACTIVE', SYSDATE
    ) RETURNING CONTRACT_ID INTO v_contract_id;

    o_contract_id := v_contract_id;

    -- generate schedules based on FIN_TYPE and product settings
    generate_schedules(v_contract_id, v_prod);

    INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
    VALUES (SEQ_AUDIT.NEXTVAL, v_contract_id, 'OPEN', 'Contract opened', SYSDATE, p_user_id);
  EXCEPTION
    WHEN e_invalid_arg THEN
      RAISE_APPLICATION_ERROR(-20010, 'Invalid input parameter.');
  END;

  PROCEDURE accrue_profit(
    p_contract_id IN NUMBER,
    p_as_of_date  IN DATE,
    p_user_id     IN VARCHAR2
  ) IS
    v_c TAB_CONTRACTS%ROWTYPE;
    v_prod TAB_PRDCTS_STTNGS%ROWTYPE;
    v_base_days NUMBER;
    v_to_accrue NUMBER := 0;
  BEGIN
    v_c := get_contract(p_contract_id);
    SELECT * INTO v_prod FROM TAB_PRDCTS_STTNGS WHERE PRDCT_ID = v_c.PRDCT_ID;
    v_base_days := NVL(v_prod.BASE_DAYS, 360);

    -- accrue for DUE but unpaid profit between last accrual/payment and as_of_date
    FOR r IN (
      SELECT i.INSTALLMENT_ID, i.DUE_DATE, i.PROFIT_DUE, i.PROFIT_PAID, i.TOTAL_DUE
      FROM TAB_INSTALLMENTS i
      WHERE i.CONTRACT_ID = p_contract_id
        AND i.STATUS IN ('DUE','OVERDUE')
    ) LOOP
      IF r.PROFIT_DUE > r.PROFIT_PAID THEN
        -- naive proportional accrual up to as_of_date if before due; if after due, full
        IF p_as_of_date < r.DUE_DATE THEN
          v_to_accrue := v_to_accrue + (r.PROFIT_DUE * (p_as_of_date - v_c.START_DATE) / (r.DUE_DATE - v_c.START_DATE));
        ELSE
          v_to_accrue := v_to_accrue + (r.PROFIT_DUE - r.PROFIT_PAID);
        END IF;
      END IF;
    END LOOP;

    IF v_to_accrue > 0 THEN
      post_gl(p_contract_id, NULL, v_prod.ACCR_INT_ACCT, v_prod.LIQD_INT_ACCT, v_to_accrue, v_c.CURRENCY_CODE, 'ACCRUAL', NULL, 'Periodic accrual');
    END IF;

    INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
      VALUES (SEQ_AUDIT.NEXTVAL, p_contract_id, 'ACCRUAL', 'Accrual posted', SYSDATE, p_user_id);
  END;

  PROCEDURE pay_installment(
    p_contract_id    IN NUMBER,
    p_installment_no IN NUMBER,
    p_amount         IN NUMBER,
    p_component      IN t_component,
    p_source_acct_id IN NUMBER,
    p_user_id        IN VARCHAR2
  ) IS
    v_inst TAB_INSTALLMENTS%ROWTYPE;
    v_c TAB_CONTRACTS%ROWTYPE;
    v_prod TAB_PRDCTS_STTNGS%ROWTYPE;
    v_paid NUMBER := 0;
  BEGIN
    assert_positive(p_amount, 'amount');
    v_c := get_contract(p_contract_id);
    SELECT * INTO v_prod FROM TAB_PRDCTS_STTNGS WHERE PRDCT_ID = v_c.PRDCT_ID;
    SELECT * INTO v_inst FROM TAB_INSTALLMENTS WHERE CONTRACT_ID = p_contract_id AND INSTL_NO = p_installment_no FOR UPDATE;

    IF p_component = 'PROFIT' THEN
      v_paid := LEAST(p_amount, v_inst.PROFIT_DUE - v_inst.PROFIT_PAID);
      UPDATE TAB_INSTALLMENTS SET PROFIT_PAID = PROFIT_PAID + v_paid WHERE INSTALLMENT_ID = v_inst.INSTALLMENT_ID;
      post_gl(p_contract_id, v_inst.INSTALLMENT_ID, v_c.SETTLEMENT_ACCT_ID, v_prod.LIQD_INT_ACCT, v_paid, v_c.CURRENCY_CODE, 'PAY_PROFIT', NULL, 'Installment profit payment');
    ELSIF p_component = 'PRINCIPAL' THEN
      v_paid := LEAST(p_amount, v_inst.PRINCIPAL_DUE - v_inst.PRINCIPAL_PAID);
      UPDATE TAB_INSTALLMENTS SET PRINCIPAL_PAID = PRINCIPAL_PAID + v_paid WHERE INSTALLMENT_ID = v_inst.INSTALLMENT_ID;
      post_gl(p_contract_id, v_inst.INSTALLMENT_ID, v_c.SETTLEMENT_ACCT_ID, v_prod.PRDCT_ACCT, v_paid, v_c.CURRENCY_CODE, 'PAY_PRINCIPAL', NULL, 'Installment principal payment');
    ELSE
      RAISE_APPLICATION_ERROR(-20011, 'Unsupported component');
    END IF;

    UPDATE TAB_INSTALLMENTS
      SET STATUS = CASE WHEN PRINCIPAL_PAID >= PRINCIPAL_DUE AND PROFIT_PAID >= PROFIT_DUE THEN 'PAID' ELSE STATUS END
    WHERE INSTALLMENT_ID = v_inst.INSTALLMENT_ID;

    INSERT INTO TAB_PAYMENTS(PAYMENT_ID, CONTRACT_ID, INSTALLMENT_ID, PAYMENT_DATE, AMOUNT, COMPONENT, SOURCE_ACCT_ID)
      VALUES (SEQ_PAYMENTS.NEXTVAL, p_contract_id, v_inst.INSTALLMENT_ID, SYSDATE, v_paid, p_component, p_source_acct_id);

    INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
      VALUES (SEQ_AUDIT.NEXTVAL, p_contract_id, 'PAYMENT', 'Installment payment', SYSDATE, p_user_id);
  END;

  PROCEDURE pay_overdue(
    p_contract_id    IN NUMBER,
    p_installment_no IN NUMBER,
    p_amount         IN NUMBER,
    p_source_acct_id IN NUMBER,
    p_user_id        IN VARCHAR2
  ) IS
  BEGIN
    -- For MVP, reuse pay_installment with PROFIT first then PRINCIPAL strategy
    pay_installment(p_contract_id, p_installment_no, p_amount, 'PROFIT', p_source_acct_id, p_user_id);
  END;

  PROCEDURE prepay_partial(
    p_contract_id IN NUMBER,
    p_prepay_amt  IN NUMBER,
    p_value_date  IN DATE,
    p_user_id     IN VARCHAR2
  ) IS
    v_c TAB_CONTRACTS%ROWTYPE;
    v_prod TAB_PRDCTS_STTNGS%ROWTYPE;
  BEGIN
    v_c := get_contract(p_contract_id);
    SELECT * INTO v_prod FROM TAB_PRDCTS_STTNGS WHERE PRDCT_ID = v_c.PRDCT_ID;

    -- Reduce outstanding by prepay and recompute future schedules per RECOMPUTE_PREPAY_BASIS (simplified to recalculating instal amount)
    post_gl(p_contract_id, NULL, v_c.SETTLEMENT_ACCT_ID, v_prod.PRDCT_ACCT, p_prepay_amt, v_c.CURRENCY_CODE, 'PREPAY', NULL, 'Partial prepayment');

    INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
      VALUES (SEQ_AUDIT.NEXTVAL, p_contract_id, 'PREPAY', 'Partial prepayment', SYSDATE, p_user_id);
  END;

  PROCEDURE mark_default_if_due(
    p_contract_id IN NUMBER,
    p_as_of_date  IN DATE,
    p_user_id     IN VARCHAR2
  ) IS
    v_c TAB_CONTRACTS%ROWTYPE;
    v_prod TAB_PRDCTS_STTNGS%ROWTYPE;
  BEGIN
    v_c := get_contract(p_contract_id);
    SELECT * INTO v_prod FROM TAB_PRDCTS_STTNGS WHERE PRDCT_ID = v_c.PRDCT_ID;
    UPDATE TAB_INSTALLMENTS i
       SET STATUS = 'DEFAULTED'
     WHERE i.CONTRACT_ID = p_contract_id
       AND i.STATUS = 'OVERDUE'
       AND p_as_of_date - i.DUE_DATE > NVL(v_prod.INSTALLMENT_OVERDUE_DAYS, 0);

    INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
      VALUES (SEQ_AUDIT.NEXTVAL, p_contract_id, 'DEFAULT_MARK', 'Marked defaulted if overdue beyond policy', SYSDATE, p_user_id);
  END;

  PROCEDURE foreclose_contract(
    p_contract_id IN NUMBER,
    p_value_date  IN DATE,
    p_user_id     IN VARCHAR2
  ) IS
    v_c TAB_CONTRACTS%ROWTYPE;
    v_prod TAB_PRDCTS_STTNGS%ROWTYPE;
    v_outstanding NUMBER := 0;
  BEGIN
    v_c := get_contract(p_contract_id);
    SELECT * INTO v_prod FROM TAB_PRDCTS_STTNGS WHERE PRDCT_ID = v_c.PRDCT_ID;

    -- Sum remaining dues
    SELECT NVL(SUM((PRINCIPAL_DUE-PRINCIPAL_PAID)+(PROFIT_DUE-PROFIT_PAID)),0)
      INTO v_outstanding
      FROM TAB_INSTALLMENTS WHERE CONTRACT_ID = p_contract_id AND STATUS <> 'PAID';

    post_gl(p_contract_id, NULL, v_c.SETTLEMENT_ACCT_ID, v_prod.PRDCT_ACCT, v_outstanding, v_c.CURRENCY_CODE, 'FORECLOSE', NULL, 'Foreclosure - full settlement');

    UPDATE TAB_INSTALLMENTS SET STATUS = 'PAID', PRINCIPAL_PAID = PRINCIPAL_DUE, PROFIT_PAID = PROFIT_DUE
     WHERE CONTRACT_ID = p_contract_id AND STATUS <> 'PAID';

    UPDATE TAB_CONTRACTS SET STATUS = 'CLOSED', UPDATED_AT = SYSDATE WHERE CONTRACT_ID = p_contract_id;

    INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
      VALUES (SEQ_AUDIT.NEXTVAL, p_contract_id, 'FORECLOSE', 'Contract foreclosed', SYSDATE, p_user_id);
  END;

  PROCEDURE amend_contract(
    p_contract_id IN NUMBER,
    p_effective_date IN DATE,
    p_new_maturity_date IN DATE,
    p_principal_delta   IN NUMBER,
    p_new_profit_rate   IN NUMBER,
    p_user_id           IN VARCHAR2
  ) IS
  BEGIN
    -- Placeholder for detailed recomputation per settings
    INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
      VALUES (SEQ_AUDIT.NEXTVAL, p_contract_id, 'AMEND', 'Contract amended', SYSDATE, p_user_id);
  END;

  PROCEDURE reschedule_contract(
    p_contract_id IN NUMBER,
    p_new_tenor   IN NUMBER,
    p_new_freq    IN NUMBER,
    p_user_id     IN VARCHAR2
  ) IS
  BEGIN
    -- Placeholder for detailed reschedule rules
    INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
      VALUES (SEQ_AUDIT.NEXTVAL, p_contract_id, 'RESCHEDULE', 'Contract rescheduled', SYSDATE, p_user_id);
  END;

  PROCEDURE close_if_fully_paid(
    p_contract_id IN NUMBER,
    p_user_id     IN VARCHAR2
  ) IS
    v_cnt NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_cnt FROM TAB_INSTALLMENTS WHERE CONTRACT_ID = p_contract_id AND STATUS <> 'PAID';
    IF v_cnt = 0 THEN
      UPDATE TAB_CONTRACTS SET STATUS = 'CLOSED', UPDATED_AT = SYSDATE WHERE CONTRACT_ID = p_contract_id;
      INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
        VALUES (SEQ_AUDIT.NEXTVAL, p_contract_id, 'CLOSE', 'Closed after last installment', SYSDATE, p_user_id);
    END IF;
  END;

  PROCEDURE renew_contract(
    p_contract_id IN NUMBER,
    p_renewal_amount IN NUMBER,
    p_user_id     IN VARCHAR2
  ) IS
  BEGIN
    INSERT INTO TAB_CONTRACT_AUDIT(AUDIT_ID, CONTRACT_ID, EVENT_TYPE, EVENT_DESC, EVENT_DATE, USER_ID)
      VALUES (SEQ_AUDIT.NEXTVAL, p_contract_id, 'RENEW', 'Contract renewed', SYSDATE, p_user_id);
  END;

END PKG_FINANCE_OPS;
/ 
