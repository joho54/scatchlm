import { useAuthStore } from "../src/stores/authStore";
import { supabase } from "../src/services/supabase";

const mockAuth = supabase.auth as jest.Mocked<typeof supabase.auth>;

beforeEach(() => {
  jest.clearAllMocks();
  useAuthStore.setState({ session: null, loading: true });
});

describe("authStore", () => {
  it("initialize loads session and sets loading false", async () => {
    const mockSession = { access_token: "token-123", user: { id: "u1" } };
    (mockAuth.getSession as jest.Mock).mockResolvedValue({
      data: { session: mockSession },
    });

    await useAuthStore.getState().initialize();

    expect(mockAuth.getSession).toHaveBeenCalled();
    expect(useAuthStore.getState().session).toEqual(mockSession);
    expect(useAuthStore.getState().loading).toBe(false);
  });

  it("initialize with no session sets null", async () => {
    (mockAuth.getSession as jest.Mock).mockResolvedValue({
      data: { session: null },
    });

    await useAuthStore.getState().initialize();

    expect(useAuthStore.getState().session).toBeNull();
    expect(useAuthStore.getState().loading).toBe(false);
  });

  it("signIn returns null on success", async () => {
    (mockAuth.signInWithPassword as jest.Mock).mockResolvedValue({
      error: null,
    });

    const error = await useAuthStore.getState().signIn("a@b.com", "pass");

    expect(mockAuth.signInWithPassword).toHaveBeenCalledWith({
      email: "a@b.com",
      password: "pass",
    });
    expect(error).toBeNull();
  });

  it("signIn returns error message on failure", async () => {
    (mockAuth.signInWithPassword as jest.Mock).mockResolvedValue({
      error: { message: "Invalid credentials" },
    });

    const error = await useAuthStore.getState().signIn("a@b.com", "wrong");

    expect(error).toBe("Invalid credentials");
  });

  it("signUp returns null on success", async () => {
    (mockAuth.signUp as jest.Mock).mockResolvedValue({ error: null });

    const error = await useAuthStore.getState().signUp("a@b.com", "pass");

    expect(mockAuth.signUp).toHaveBeenCalledWith({
      email: "a@b.com",
      password: "pass",
    });
    expect(error).toBeNull();
  });

  it("signUp returns error message on failure", async () => {
    (mockAuth.signUp as jest.Mock).mockResolvedValue({
      error: { message: "Email taken" },
    });

    const error = await useAuthStore.getState().signUp("dup@b.com", "pass");

    expect(error).toBe("Email taken");
  });

  it("signOut clears session", async () => {
    useAuthStore.setState({ session: { access_token: "x" } as any });
    (mockAuth.signOut as jest.Mock).mockResolvedValue({});

    await useAuthStore.getState().signOut();

    expect(mockAuth.signOut).toHaveBeenCalled();
    expect(useAuthStore.getState().session).toBeNull();
  });
});
