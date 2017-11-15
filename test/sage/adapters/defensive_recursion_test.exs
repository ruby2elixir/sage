defmodule Sage.Adapters.DefensiveRecursionTest do
  use Sage.EffectsCase

  # TODO: effects are created .. for all transactions
  describe "transactions" do
    test "are executed" do
      result =
        new()
        |> run(:step1, transaction(:t1), compensation())
        |> run(:step2, transaction(:t2), compensation())
        |> run(:step3, {__MODULE__, :mfa_transaction, [transaction(:t3)]}, compensation())
        |> assert_finally_succeeds([a: :b])
        |> execute(a: :b)

      assert_effects [:t1, :t2, :t3]
      assert result == {:ok, :t3, %{step1: :t1, step2: :t2, step3: :t3}}
    end

    test "are awaiting on next synchronous operation when executes asynchronous transactions" do
      result =
        new()
        |> run_async(:step1, transaction(:t1), not_strict_compensation())
        |> run_async(:step2, transaction(:t2), not_strict_compensation())
        |> run(:step3, fn effects_so_far, opts ->
          assert effects_so_far == %{step1: :t1, step2: :t2}
          transaction(:t3).(effects_so_far, opts)
        end)
        |> assert_finally_succeeds([a: :b])
        |> execute(a: :b)

      assert_effect :t1
      assert_effect :t2
      assert_effect :t3

      assert result == {:ok, :t3, %{step1: :t1, step2: :t2, step3: :t3}}
    end

    test "are returning last operation result when executes asynchronous transactions on last steps" do
      result =
        new()
        |> run_async(:step1, transaction(:t1), not_strict_compensation())
        |> run_async(:step2, transaction(:t2), not_strict_compensation())
        |> run_async(:step3, transaction(:t3), not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run_async(:step5, transaction(:t5), not_strict_compensation())
        |> assert_finally_succeeds([a: :b])
        |> execute(a: :b)

      assert_effect :t1
      assert_effect :t2
      assert_effect :t3
      assert_effect :t4
      assert_effect :t5

      assert result == {:ok, :t5, %{step1: :t1, step2: :t2, step3: :t3, step4: :t4, step5: :t5}}
    end
  end

  test "effects are not compensated for operations with :noop compensation" do
    result =
      new()
      |> run(:step1, transaction_with_error(:t1))
      |> assert_finally_fails()
      |> execute(a: :b)

    assert_effects([:t1])
    assert result == {:error, :t1}
  end

  # TODO: effects are compensated
  describe "effects are compensated" do
    test "when transaction fails" do
      result =
        new()
        |> run(:step1, transaction(:t1), compensation())
        |> run(:step2, transaction(:t2), compensation())
        |> run(:step3, transaction_with_error(:t3), compensation())
        |> assert_finally_fails()
        |> execute(a: :b)


      assert_no_effects()
      assert result == {:error, :t3}
    end

    test "for executed async transactions when transaction fails" do
      test_pid = self()
      cmp = fn effect_to_compensate, name_and_reason, opts ->
        assert name_and_reason == {:step3, :t3}
        send test_pid, {:compensate, effect_to_compensate}
        not_strict_compensation().(effect_to_compensate, name_and_reason, opts)
      end

      result =
        new()
        |> run_async(:step1, transaction(:t1), cmp)
        |> run_async(:step2, transaction(:t2), cmp)
        |> run(:step3, transaction_with_error(:t3), cmp)
        |> assert_finally_fails()
        |> execute(a: :b)

      assert_receive {:compensate, :t2}
      assert_receive {:compensate, :t1}

      assert_no_effects()
      assert result == {:error, :t3}
    end

    test "for all started async transaction when one of them failed" do
      test_pid = self()
      cmp = fn effect_to_compensate, name_and_reason, opts ->
        send test_pid, {:compensate, effect_to_compensate}
        not_strict_compensation().(effect_to_compensate, name_and_reason, opts)
      end

      result =
        new()
        |> run_async(:step1, transaction_with_error(:t1), cmp)
        |> run_async(:step2, transaction(:t2), cmp)
        |> run_async(:step3, transaction(:t3), cmp)
        |> assert_finally_fails()
        |> execute(a: :b)

      # Since all async tasks are run in parallel
      # after one of them failed, we await for rest of them
      # and compensate their effects
      assert_receive {:compensate, :t2}
      assert_receive {:compensate, :t1}
      assert_receive {:compensate, :t3}

      assert_no_effects()
      assert result == {:error, :t1}
    end

    test "with preserved error name and reason for synchronous transactions" do
      result =
        new()
        |> run(:step1, transaction(:t1), compensation())
        |> run(:step2, transaction_with_error(:t2), compensation())
        |> run(:step3, transaction_with_error(:t3), compensation())
        |> assert_finally_fails()
        |> execute(a: :b)


      assert_no_effects()
      assert result == {:error, :t2}
    end

    test "with preserved error name and reason for asynchronous transactions" do
      cmp = fn effect_to_compensate, name_and_reason, opts ->
        assert name_and_reason == {:step2, :t2}
        not_strict_compensation().(effect_to_compensate, name_and_reason, opts)
      end

      result =
        new()
        |> run_async(:step1, transaction(:t1), cmp)
        |> run_async(:step2, transaction_with_error(:t2), cmp)
        |> run_async(:step3, transaction(:t3), cmp)
        |> assert_finally_fails()
        |> execute(a: :b)

      assert_no_effects()
      assert result == {:error, :t2}
    end

    test "when transaction raised an exception" do
      test_pid = self()
      tx = transaction(:t3)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t3}
        tx.(effects_so_far, opts)
      end

      assert_raise RuntimeError, "error while creating t5", fn ->
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, transaction(:t2), compensation())
        |> run_async(:step3, tx, not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run(:step5, transaction_with_exception(:t5), compensation(:t5))
        |> assert_finally_fails()
        |> execute()
      end

      # Retries are applying when exception is raised
      assert_receive {:execute, :t3}
      assert_receive {:execute, :t3}

      assert_no_effects()
    end

    test "when transaction throws an error" do
      test_pid = self()
      tx = transaction(:t3)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t3}
        tx.(effects_so_far, opts)
      end

      assert catch_throw(
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, transaction(:t2), compensation())
        |> run_async(:step3, tx, not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run(:step5, transaction_with_throw(:t5), compensation(:t5))
        |> assert_finally_fails()
        |> execute()
      ) == "error while creating t5"

      # Retries are applying when error is thrown
      assert_receive {:execute, :t3}
      assert_receive {:execute, :t3}

      assert_no_effects()
    end

    test "when transaction exits" do
      test_pid = self()
      tx = transaction(:t3)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t3}
        tx.(effects_so_far, opts)
      end

      assert catch_exit(
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, transaction(:t2), compensation())
        |> run_async(:step3, tx, not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run(:step5, transaction_with_exit(:t5), compensation(:t5))
        |> assert_finally_fails()
        |> execute()
      ) == "error while creating t5"

      # Retries are applying when tx exited
      assert_receive {:execute, :t3}
      assert_receive {:execute, :t3}

      assert_no_effects()
    end

    test "when transaction has malformed return" do
      test_pid = self()
      tx = transaction(:t3)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t3}
        tx.(effects_so_far, opts)
      end

      message = ~r"""
      ^unexpected return from transaction .*,
      expected it to be {:ok, effect}, {:error, reason} or {:abort, reason}, got:

        {:bad_returns, :are_bad_mmmkay}$
      """

      assert_raise Sage.MalformedTransactionReturnError, message, fn ->
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, transaction(:t2), compensation())
        |> run_async(:step3, tx, not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run(:step5, transaction_with_invalid_return(:t5), compensation(:t5))
        |> assert_finally_fails()
        |> execute()
      end

      # Retries are applying when tx exited
      assert_receive {:execute, :t3}
      assert_receive {:execute, :t3}

      assert_no_effects()
    end

    test "when async transaction timed out" do
      test_pid = self()
      tx = transaction(:t3)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t3}
        tx.(effects_so_far, opts)
      end

      message = """
      asynchronous transaction for operation step5 timed out,
      expected it to return within 10 microseconds
      """

      assert_raise Sage.AsyncTransactionTimeoutError, message, fn ->
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(2))
        |> run(:step2, transaction(:t2), compensation())
        |> run_async(:step3, tx, not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run_async(:step5, transaction_with_sleep(:t5, 20), not_strict_compensation(:t5), timeout: 10)
        |> assert_finally_fails()
        |> execute()
      end

      # Retries are applying when tx timed out
      assert_receive {:execute, :t3}
      assert_receive {:execute, :t3}

      assert_no_effects()
    end

    test "when async transaction raised an exception" do
      test_pid = self()
      tx = transaction(:t3)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t3}
        tx.(effects_so_far, opts)
      end

      assert_raise RuntimeError, "error while creating t5", fn ->
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, transaction(:t2), compensation())
        |> run_async(:step3, tx, not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run_async(:step5, transaction_with_exception(:t5), not_strict_compensation(:t5))
        |> assert_finally_fails()
        |> execute()
      end

      # Retries are applying when exception is raised
      assert_receive {:execute, :t3}
      assert_receive {:execute, :t3}

      assert_no_effects()
    end

    test "when async transaction throws an error" do
      test_pid = self()
      tx = transaction(:t3)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t3}
        tx.(effects_so_far, opts)
      end

      assert catch_throw(
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, transaction(:t2), compensation())
        |> run_async(:step3, tx, not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run_async(:step5, transaction_with_throw(:t5), not_strict_compensation(:t5))
        |> assert_finally_fails()
        |> execute()
      ) == "error while creating t5"

      # Retries are applying when error is thrown
      assert_receive {:execute, :t3}
      assert_receive {:execute, :t3}

      assert_no_effects()
    end

    test "when async transaction exits" do
      test_pid = self()
      tx = transaction(:t3)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t3}
        tx.(effects_so_far, opts)
      end

      assert catch_exit(
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, transaction(:t2), compensation())
        |> run_async(:step3, tx, not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run_async(:step5, transaction_with_exit(:t5), not_strict_compensation(:t5))
        |> assert_finally_fails()
        |> execute()
      ) == "error while creating t5"

      # Retries are applying when tx exited
      assert_receive {:execute, :t3}
      assert_receive {:execute, :t3}

      assert_no_effects()
    end

    test "when async transaction has malformed return" do
      test_pid = self()
      tx = transaction(:t3)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t3}
        tx.(effects_so_far, opts)
      end

      message = ~r"""
      ^unexpected return from transaction .*,
      expected it to be {:ok, effect}, {:error, reason} or {:abort, reason}, got:

        {:bad_returns, :are_bad_mmmkay}$
      """

      assert_raise Sage.MalformedTransactionReturnError, message, fn ->
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, transaction(:t2), compensation())
        |> run_async(:step3, tx, not_strict_compensation())
        |> run_async(:step4, transaction(:t4), not_strict_compensation())
        |> run_async(:step5, transaction_with_invalid_return(:t5), not_strict_compensation(:t5))
        |> assert_finally_fails()
        |> execute()
      end

      # Retries are applying when tx exited
      assert_receive {:execute, :t3}
      assert_receive {:execute, :t3}

      assert_no_effects()
    end
  end

  test "raise in compensations are not silenced by default" do
    test_pid = self()
    tx = transaction(:t3)
    tx = fn effects_so_far, opts ->
      send test_pid, {:execute, :t3}
      tx.(effects_so_far, opts)
    end

    assert_raise RuntimeError, "error while compensating t5", fn ->
      new()
      |> run(:step1, transaction(:t1), compensation_with_retry(3))
      |> run(:step2, transaction(:t2), compensation())
      |> run_async(:step3, tx, not_strict_compensation())
      |> run_async(:step4, transaction(:t4), not_strict_compensation())
      |> run(:step5, transaction_with_error(:t5), compensation_with_exception(:t5))
      |> assert_finally_fails()
      |> execute()
    end

    # Retries are applying when tx exited
    assert_receive {:execute, :t3}
    refute_receive {:execute, :t3}

    assert_effect :t1
    assert_effect :t2
    assert_effect :t3
    assert_effect :t4
  end

  describe "final hooks" do
    test "can be omitted" do
      result =
        new()
        |> run(:step1, transaction(:t1), compensation())
        |> execute()

      assert_effects [:t1]
      assert result == {:ok, :t1, %{step1: :t1}}
    end

    test "are triggered on successes" do
      test_pid = self()

      result =
        new()
        |> run(:step1, transaction(:t1), compensation())
        |> finally(&{send(test_pid, &1), &2})
        |> finally({__MODULE__, :do_send, [test_pid]})
        |> execute(a: :b)

      assert_receive :ok
      assert_receive :ok

      assert_effects [:t1]
      assert result == {:ok, :t1, %{step1: :t1}}
    end

    test "are triggered on failure" do
      test_pid = self()

      result =
        new()
        |> run(:step1, transaction_with_error(:t1), compensation())
        |> finally(&{send(test_pid, &1), &2})
        |> finally({__MODULE__, :do_send, [test_pid]})
        |> execute(a: :b)

      assert_receive :error
      assert_receive :error

      assert_no_effects()
      assert result == {:error, :t1}
    end

    test "exceptions, throws and exits are logged" do
      import ExUnit.CaptureLog

      test_pid = self()

      final_hook_with_raise = fn status, _opts ->
        send(test_pid, status)
        raise "Final hook raised an exception"
      end

      final_hook_with_throw = fn status, _opts ->
        send(test_pid, status)
        throw "Final hook threw an error"
      end

      final_hook_with_exit = fn status, _opts ->
        send(test_pid, status)
        exit "Final hook exited"
      end

      log =
        capture_log(fn ->
          result =
            new()
            |> run(:step1, transaction_with_error(:t1), compensation())
            |> finally(final_hook_with_raise)
            |> finally(final_hook_with_throw)
            |> finally(final_hook_with_exit)
            |> finally({__MODULE__, :final_hook_with_raise, [test_pid]})
            |> finally({__MODULE__, :final_hook_with_throw, [test_pid]})
            |> finally({__MODULE__, :final_hook_with_exit, [test_pid]})
            |> execute(a: :b)


          assert_no_effects()
          assert result == {:error, :t1}
        end)

      assert_receive :error
      assert_receive :error
      assert_receive :error
      assert_receive :error
      assert_receive :error
      assert_receive :error
      refute_receive :error

      assert log =~ "Final mfa hook raised an exception"
      assert log =~ "Final mfa hook threw an error"
      assert log =~ "Final mfa hook exited"

      assert log =~ "Final hook raised an exception"
      assert log =~ "Final hook threw an error"
      assert log =~ "Final hook exited"
    end
  end

  describe "global options" do
    test "are sent to transaction" do
      execute_opts = %{foo: "bar"}
      tx = fn effects_so_far, opts ->
        assert opts == execute_opts
        transaction(:t1).(effects_so_far, opts)
      end

      result =
        new()
        |> run(:step1, tx, compensation())
        |> execute(execute_opts)

      assert result == {:ok, :t1, %{step1: :t1}}

      assert_effects [:t1]
    end

    test "are sent to compensation" do
      execute_opts = %{foo: "bar"}
      cmp = fn effect_to_compensate, name_and_reason, opts ->
        assert opts == execute_opts
        assert name_and_reason == {:step1, :t1}
        compensation(:t1).(effect_to_compensate, name_and_reason, opts)
      end

      result =
        new()
        |> run(:step1, transaction_with_error(:t1), cmp)
        |> execute(execute_opts)

      assert_no_effects()
      assert result == {:error, :t1}
    end

    test "are sent to final hook" do
      execute_opts = %{foo: "bar"}
      final_hook = fn state, opts ->
        assert state == :ok
        assert opts == execute_opts
      end

      result =
        new()
        |> run(:step1, transaction(:t1))
        |> finally(final_hook)
        |> execute(execute_opts)

      assert_effects [:t1]
      assert result == {:ok, :t1, %{step1: :t1}}
    end
  end

  describe "retries" do
    test "are executing transactions again" do
      test_pid = self()
      tx = transaction(:t2)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t2}
        tx.(effects_so_far, opts)
      end

      result =
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, tx, compensation())
        |> run(:step3, transaction_with_n_errors(2, :t3), compensation())
        |> assert_finally_succeeds([a: :b])
        |> execute(a: :b)

      assert_receive {:execute, :t2}
      assert_receive {:execute, :t2}
      assert_receive {:execute, :t2}

      assert_effects [:t1, :t2, :t3]
      assert result == {:ok, :t3, %{step1: :t1, step2: :t2, step3: :t3}}
    end

    test "are ignored when retry limit exceeded" do
      test_pid = self()
      tx = transaction(:t2)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t2}
        tx.(effects_so_far, opts)
      end

      result =
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, tx, compensation())
        |> run(:step3, transaction_with_n_errors(4, :t3), compensation())
        |> assert_finally_fails()
        |> execute(a: :b)

      assert_receive {:execute, :t2}
      assert_receive {:execute, :t2}
      assert_receive {:execute, :t2}
      refute_receive {:execute, :t2}

      assert_no_effects()
      assert result == {:error, :t3}
    end

    test "are ignored when compensation aborted the sage" do
      test_pid = self()
      tx = transaction(:t2)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t2}
        tx.(effects_so_far, opts)
      end

      result =
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, tx, compensation())
        |> run(:step3, transaction_with_n_errors(1, :t3), compensation_with_abort())
        |> assert_finally_fails()
        |> execute(a: :b)

      assert_receive {:execute, :t2}
      refute_receive {:execute, :t2}

      assert_no_effects()
      assert result == {:error, :t3}
    end

    test "are ignored when transaction aborted the sage" do
      test_pid = self()
      tx = transaction(:t2)
      tx = fn effects_so_far, opts ->
        send test_pid, {:execute, :t2}
        tx.(effects_so_far, opts)
      end

      result =
        new()
        |> run(:step1, transaction(:t1), compensation_with_retry(3))
        |> run(:step2, tx, compensation())
        |> run(:step3, transaction_with_abort(:t3), compensation())
        |> assert_finally_fails()
        |> execute(a: :b)

      assert_receive {:execute, :t2}
      refute_receive {:execute, :t2}

      assert_no_effects()
      assert result == {:error, :t3}
    end
  end

  describe "circuit breaker" do
    test "response is used as transaction effect" do
      result =
        new()
        |> run(:step1, transaction_with_error(:t1), compensation_with_circuit_breaker(:t1_defaults))
        |> assert_finally_succeeds()
        |> execute(a: :b)

      assert_no_effects()
      assert result == {:ok, :t1_defaults, %{step1: :t1_defaults}}
    end

    test "raises exception when returned from compensation which is not responsible for failed transaction" do
      message = """
      Compensation step1 tried to apply circuit
      breaker on a failure which occurred on transaction
      step2 which it is not responsible for.

      If you trying to implement circuit breaker, always match for a
      failed operation name in compensating function:

      compensation =
        fn
          effect_to_compensate, {:my_step, _failure_reason}, _opts ->
            # 1. Compensate the side effect
            # 2. Continue with circuit breaker

          effect_to_compensate, {_not_my_step, _failure_reason}, _opts ->
            # Compensate the side effect
        end
      """

      assert_raise Sage.UnexpectedCircuitBreakError, message, fn ->
        new()
        |> run(:step1, transaction(:t1), compensation_with_circuit_breaker(:t1_defaults))
        |> run(:step2, transaction_with_error(:t2), compensation())
        |> assert_finally_fails()
        |> execute(a: :b)
      end

      assert_no_effects()
    end
  end

  def do_send(msg, _opts, pid), do: send(pid, msg)

  def mfa_transaction(effects_so_far, opts, cb), do: cb.(effects_so_far, opts)

  def final_hook_with_raise(status, _opts, test_pid) do
    send(test_pid, status)
    raise "Final mfa hook raised an exception"
  end

  def final_hook_with_throw(status, _opts, test_pid) do
    send(test_pid, status)
    raise "Final mfa hook threw an error"
  end

  def final_hook_with_exit(status, _opts, test_pid) do
    send(test_pid, status)
    raise "Final mfa hook exited"
  end
end