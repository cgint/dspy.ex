defmodule Dspy.StatusMessage do
  @moduledoc "A progress message yielded by `Dspy.streamify/2`."

  @enforce_keys [:message]
  defstruct [:message]

  @type t :: %__MODULE__{message: binary()}
end
