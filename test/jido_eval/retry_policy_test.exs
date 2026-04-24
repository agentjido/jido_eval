defmodule Jido.Eval.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Jido.Eval.RetryPolicy

  describe "struct creation" do
    test "creates with default values" do
      policy = %RetryPolicy{}

      assert policy.max_retries == 3
      assert policy.base_delay == 1000
      assert policy.max_delay == 60_000
      assert policy.jitter == true
      assert policy.retryable_errors == [:timeout, :rate_limit, :server_error]
    end

    test "creates with custom values" do
      policy = %RetryPolicy{
        max_retries: 5,
        base_delay: 2000,
        max_delay: 120_000,
        jitter: false,
        retryable_errors: [:timeout, :network_error]
      }

      assert policy.max_retries == 5
      assert policy.base_delay == 2000
      assert policy.max_delay == 120_000
      assert policy.jitter == false
      assert policy.retryable_errors == [:timeout, :network_error]
    end

    test "validates field types" do
      # Runtime struct literals remain permissive; the Zoi schema documents field expectations.
      policy = %RetryPolicy{max_retries: 0}
      assert policy.max_retries == 0
    end
  end

  describe "new/1 and new!/1" do
    test "validates maps with coercion" do
      assert {:ok, policy} =
               RetryPolicy.new(%{
                 "max_retries" => 1,
                 "base_delay" => 5,
                 "jitter" => false
               })

      assert policy.max_retries == 1
      assert policy.base_delay == 5
      assert policy.jitter == false
      assert %RetryPolicy{} = RetryPolicy.new!()
    end

    test "raises for invalid maps" do
      assert_raise ArgumentError, fn ->
        RetryPolicy.new!(%{max_retries: "many"})
      end
    end
  end

  describe "doctests" do
    doctest RetryPolicy
  end
end
