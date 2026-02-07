defmodule Dspy.Tools.SafeMath do
  @moduledoc false

  @type error_reason :: :invalid_expression | :mismatched_parentheses | :division_by_zero

  @spec eval(String.t()) :: {:ok, number()} | {:error, error_reason()}
  def eval(expr) when is_binary(expr) do
    with {:ok, tokens} <- tokenize(expr),
         {:ok, rpn} <- to_rpn(tokens),
         {:ok, result} <- eval_rpn(rpn) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_expression}
    end
  end

  # --- Tokenize ---

  defp tokenize(expr) do
    expr = String.trim(expr)

    if expr == "" do
      {:error, :invalid_expression}
    else
      scan(expr, [], :start)
    end
  end

  defp scan(<<>>, acc, _state), do: {:ok, Enum.reverse(acc)}

  defp scan(<<c::utf8, rest::binary>>, acc, state) when c in [9, 10, 13, 32] do
    scan(rest, acc, state)
  end

  defp scan(<<c::utf8, rest::binary>>, acc, state) when c in ~c"(+-*/()" do
    token =
      case c do
        ?( -> :lparen
        ?) -> :rparen
        ?+ -> :plus
        ?- -> if state in [:start, :op, :lparen], do: :uminus, else: :minus
        ?* -> :mul
        ?/ -> :div
      end

    next_state =
      cond do
        token == :lparen -> :lparen
        token == :rparen -> :num
        token in [:plus, :minus, :mul, :div, :uminus] -> :op
        true -> :op
      end

    scan(rest, [token | acc], next_state)
  end

  defp scan(binary, acc, _state) do
    case consume_number(binary) do
      {:ok, number, rest} ->
        scan(rest, [{:num, number} | acc], :num)

      :error ->
        {:error, :invalid_expression}
    end
  end

  defp consume_number(binary) do
    # Match a simple int/float: 12, 12.3, .5, 0.5
    case Regex.run(~r/^([0-9]+(?:\.[0-9]+)?|\.[0-9]+)(.*)$/s, binary, capture: :all_but_first) do
      [num_str, rest] ->
        number =
          if String.contains?(num_str, ".") do
            String.to_float(num_str)
          else
            String.to_integer(num_str)
          end

        {:ok, number, rest}

      _ ->
        :error
    end
  end

  # --- Shunting-yard to RPN ---

  defp to_rpn(tokens) do
    result =
      Enum.reduce_while(tokens, {[], []}, fn token, {out, ops} ->
        case token do
          {:num, _} ->
            {:cont, {[token | out], ops}}

          :lparen ->
            {:cont, {out, [:lparen | ops]}}

          :rparen ->
            case pop_until_lparen(out, ops) do
              {:ok, out, ops} -> {:cont, {out, ops}}
              {:error, _} = e -> {:halt, e}
            end

          op when op in [:plus, :minus, :mul, :div, :uminus] ->
            {out, ops} = pop_ops(out, ops, op)
            {:cont, {out, [op | ops]}}

          _ ->
            {:halt, {:error, :invalid_expression}}
        end
      end)

    case result do
      {:error, _reason} = e ->
        e

      {out, ops} ->
        case finalize_ops(out, ops) do
          {:ok, rpn} -> {:ok, Enum.reverse(rpn)}
          {:error, _} = e -> e
        end
    end
  end

  defp precedence(:uminus), do: 3
  defp precedence(:mul), do: 2
  defp precedence(:div), do: 2
  defp precedence(:plus), do: 1
  defp precedence(:minus), do: 1

  defp right_assoc?(:uminus), do: true
  defp right_assoc?(_), do: false

  defp pop_ops(out, [top | rest] = ops, op)
       when top in [:plus, :minus, :mul, :div, :uminus] do
    p_top = precedence(top)
    p_op = precedence(op)

    cond do
      (right_assoc?(op) and p_op < p_top) or (!right_assoc?(op) and p_op <= p_top) ->
        pop_ops([top | out], rest, op)

      true ->
        {out, ops}
    end
  end

  defp pop_ops(out, ops, _op), do: {out, ops}

  defp pop_until_lparen(_out, []), do: {:error, :mismatched_parentheses}

  defp pop_until_lparen(out, [:lparen | rest]), do: {:ok, out, rest}

  defp pop_until_lparen(out, [top | rest]) do
    pop_until_lparen([top | out], rest)
  end

  defp finalize_ops(out, ops) do
    if Enum.any?(ops, &(&1 in [:lparen, :rparen])) do
      {:error, :mismatched_parentheses}
    else
      {:ok, Enum.reduce(ops, out, fn op, out -> [op | out] end)}
    end
  end

  # --- Eval RPN ---

  defp eval_rpn(tokens) do
    Enum.reduce_while(tokens, {:ok, []}, fn token, {:ok, stack} ->
      case token do
        {:num, n} ->
          {:cont, {:ok, [n | stack]}}

        :uminus ->
          case stack do
            [a | rest] -> {:cont, {:ok, [-a | rest]}}
            _ -> {:halt, {:error, :invalid_expression}}
          end

        op when op in [:plus, :minus, :mul, :div] ->
          case stack do
            [b, a | rest] ->
              case apply_op(op, a, b) do
                {:ok, v} -> {:cont, {:ok, [v | rest]}}
                {:error, _} = e -> {:halt, e}
              end

            _ ->
              {:halt, {:error, :invalid_expression}}
          end

        _ ->
          {:halt, {:error, :invalid_expression}}
      end
    end)
    |> case do
      {:ok, [result]} -> {:ok, result}
      {:ok, _} -> {:error, :invalid_expression}
      {:error, _} = e -> e
    end
  end

  defp apply_op(:plus, a, b), do: {:ok, a + b}
  defp apply_op(:minus, a, b), do: {:ok, a - b}
  defp apply_op(:mul, a, b), do: {:ok, a * b}

  defp apply_op(:div, _a, 0), do: {:error, :division_by_zero}
  defp apply_op(:div, a, b), do: {:ok, a / b}
end
