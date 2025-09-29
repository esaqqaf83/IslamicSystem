-- Sample calls to exercise PKG_FINANCE_OPS

DECLARE
  v_contract_id NUMBER;
BEGIN
  PKG_FINANCE_OPS.open_contract(
    p_contract_no        => 'CNTR-0001',
    p_customer_id        => (SELECT CUSTOMER_ID FROM TAB_CUSTOMERS WHERE CIF_NO = 'CIF1001'),
    p_prdct_code         => 'MRB001',
    p_fin_product_type   => 'Murabaha',
    p_principal_amt      => 120000,
    p_currency_code      => 'YER',
    p_start_date         => DATE '2025-01-01',
    p_tenor              => 12,
    p_tenor_unit         => 'MONTHS',
    p_frequency          => 1,
    p_settlement_acct_id => (SELECT ACCOUNT_ID FROM TAB_ACCOUNTS WHERE ACCT_NO = 'ACC-SETT-1001'),
    p_user_id            => 'SYS',
    o_contract_id        => v_contract_id
  );

  DBMS_OUTPUT.PUT_LINE('Opened contract ID='||v_contract_id);

  -- Accrual as of Jan 31
  PKG_FINANCE_OPS.accrue_profit(v_contract_id, DATE '2025-01-31', 'SYS');

  -- Pay first installment profit part (example)
  PKG_FINANCE_OPS.pay_installment(v_contract_id, 1, 1000, 'PROFIT', NULL, 'SYS');

  -- Partial prepayment
  PKG_FINANCE_OPS.prepay_partial(v_contract_id, 20000, DATE '2025-03-15', 'SYS');

  -- Foreclosure example
  -- PKG_FINANCE_OPS.foreclose_contract(v_contract_id, DATE '2025-06-01', 'SYS');
END;
/
