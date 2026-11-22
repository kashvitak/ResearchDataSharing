package com.researchip.web;

import com.researchip.service.AuthService;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

/** Every /api request except /api/auth/** needs "Authorization: Bearer <token>". */
@Component
public class AuthInterceptor implements HandlerInterceptor {
    private final AuthService auth;

    public AuthInterceptor(AuthService auth) {
        this.auth = auth;
    }

    @Override
    public boolean preHandle(HttpServletRequest req, HttpServletResponse res, Object handler) throws Exception {
        if (req.getMethod().equals("OPTIONS")) return true;
        String h = req.getHeader("Authorization");
        String did = (h != null && h.startsWith("Bearer ")) ? auth.didForToken(h.substring(7)) : null;
        if (did == null) {
            res.setStatus(401);
            res.setContentType("application/json");
            res.getWriter().write("{\"error\":\"Not logged in\"}");
            return false;
        }
        req.setAttribute("did", did);
        return true;
    }
}
